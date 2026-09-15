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
      'Операция подтверждена на другом устройстве. Статус читается с сервера.';

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
  String get coreNotRun => 'Mihomo: проверка ядром не выполнена';

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
  String get sshTitle => 'SSH-подключение';

  @override
  String get sshServerName => 'Имя сервера (необязательно)';

  @override
  String get sshEdit => 'Изменить подключение';

  @override
  String get sshEditHelp =>
      'Переименование сохраняет подключение. Сохранение изменённых параметров SSH завершит сеанс; подключитесь снова, чтобы применить их.';

  @override
  String get sshOsUnknown => 'Версия ОС появится после подключения';

  @override
  String get sshReplaceServer => 'Это другой сервер';

  @override
  String get sshReplaceServerHelp =>
      'Продолжайте, только если намеренно заменили сервер или изменили его адрес. Сверьте новый отпечаток через консоль VPS. Подтверждение заменит сохранённый доверенный ключ; отказ сохранит прежний. Реквизиты входа останутся.';

  @override
  String get sshReadOnly =>
      'Подключитесь к VPS Ubuntu x86_64 для чтения сетевых сведений.';

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
  String get sshSaved => 'Подключение сохранено на устройстве.';

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
  String get sshJumpHelp =>
      'Подключение через другой сохранённый сервер. Для каждого сервера используются его логин и SSH-ключ.';

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
  String get vpnSave => 'Сохранить и подготовить план доступов';

  @override
  String get vpnInbounds => 'VLESS inbounds';

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
      'Следующий план удалит этот inbound для всех клиентов.';

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
  String get vpnOfflinePlan =>
      'Сервер недоступен. Подтверждённые изменения выполнятся после подключения и проверки предусловий.';

  @override
  String get vpnPending =>
      'Изменения доступов ожидают выполнения на одном или нескольких серверах. Полный актуальный профиль пока не готов.';

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
      'Не удалось сформировать текущий профиль. Предыдущая сохранённая версия остаётся в истории.';

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
  String get protocolSoftware => 'Обновления протоколов';

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
  String get updatesAutomatic => 'Автоматически проверять версии протоколов';

  @override
  String get updatesSuggestions => 'Показывать предложения обновлений';

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
      'Новые релизы проверяются для 3x-ui, Xray, TrustTunnel и AmneziaWG. Проверенные обновления TrustTunnel/AmneziaWG применяются через их планы; применение обновлений 3x-ui/Xray пока недоступно.';

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
  String get vpnInternalHelp =>
      'Сохранить inbound включённым, исключить его из профилей и отозвать доступы клиентов AntiRKN через план.';

  @override
  String get vpnObserved => 'Существующий · вне управления клиентами';

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
  String get vpnRegenerateReality =>
      'Перегенерировать ключи REALITY и Short ID';

  @override
  String get vpnRealityAutomatic =>
      'Ключи REALITY и Short ID создаются автоматически и сохраняются при редактировании.';

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
  String get aptRunningHelp =>
      'Задание продолжится при закрытии приложения. Отмена дождётся завершения текущей команды APT.';

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
  String get panelConnectTitle => 'Подключить существующую панель';

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
  String get awgEndpointHelp =>
      'Выберите IP для клиентских профилей. AWG слушает UDP-порт на всех адресах сервера. Свободный порт проверяется повторно при применении.';

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
  String get ttQuic => 'QUIC / HTTP/3';

  @override
  String get ttIpv6 => 'Разрешить выход по IPv6';

  @override
  String get ttAllowPrivate => 'Разрешить доступ к внутренним сетям';

  @override
  String get ttRotate => 'Заменить пароли всех клиентов этого endpoint';

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
      'Certbot недоступен по текущим индексам APT. Запустите ручное обновление индексов и подготовьте новый план.';

  @override
  String get ttAcmeFailed =>
      'Выпуск или продление ACME завершились ошибкой. Проверьте публичный DNS, доступность порта 80 и журнал ACME на сервере.';

  @override
  String get backupTitle => 'Резервные копии';

  @override
  String get backupHelp =>
      'Сохраните серверы, клиентов, ключи, шаблоны и историю изменений в зашифрованный файл для восстановления на другой установке.';

  @override
  String get backupExport => 'Создать копию';

  @override
  String get backupImport => 'Восстановить из копии';

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
  String backupSummary(
    String date,
    int servers,
    int users,
    int changes,
    int pending,
  ) {
    return 'Создана: $date\nСерверов: $servers\nКлиентов: $users\nИзменений: $changes\nВ очереди: $pending';
  }

  @override
  String get backupReplaceHelp =>
      'Текущие серверы, клиенты, шаблоны и история будут заменены содержимым копии. Сначала сохраните отдельную копию текущих данных, если они нужны. SSH-соединения закроются. Приложение откроет восстановленное хранилище; незавершённые VPN-операции потребуют нового решения. Личные настройки этого устройства сохранятся.';

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
  String get syncConflictsTitle => 'Конфликты изменений';

  @override
  String get syncLocalHelp =>
      'Здесь можно разрешить сохранённые конфликты. Обмен через Google Drive ещё не подключён.';

  @override
  String syncConflictCount(int count) {
    return 'Конфликтов: $count';
  }

  @override
  String syncWaitingCount(int groups, int missing) {
    return 'Ожидающих групп: $groups. Недостающих предыдущих изменений: $missing.';
  }

  @override
  String syncBlockedCount(int count) {
    return 'Групп с несовместимыми данными: $count. Исправьте локальные данные, затем повторите применение.';
  }

  @override
  String get syncChanged =>
      'Состав конфликта изменился. Откройте его заново и повторите выбор.';

  @override
  String get syncStorageError =>
      'Не удалось применить выбранную версию. Обновите список и проверьте совместимость данных.';

  @override
  String get syncEffectsBlocked =>
      'Сначала разрешите конфликты изменений в настройках. Серверные действия и выдача профилей приостановлены.';

  @override
  String get syncRefresh => 'Обновить список';

  @override
  String get syncRetry => 'Повторить применение';

  @override
  String get syncChooseHelp =>
      'Просмотрите версии и выберите одну. Содержимое может включать пароли и ключи. Решение сохранится как новое изменение; серверные операции требуют отдельного действия.';

  @override
  String syncVariant(int number) {
    return 'Версия $number';
  }

  @override
  String get syncDeleted => 'Удаление ресурса';

  @override
  String get syncReveal => 'Показать содержимое и секреты';

  @override
  String get syncHide => 'Скрыть содержимое';

  @override
  String get syncSelect => 'Выбрать эту версию';

  @override
  String get syncResolve => 'Сохранить решение';

  @override
  String get syncKindServer => 'Сервер';

  @override
  String get syncKindTemplate => 'Базовый шаблон';

  @override
  String get syncKindUser => 'VPN-клиент';

  @override
  String get syncKindVless => 'VLESS inbound';

  @override
  String get syncKindAwg => 'Интерфейс AmneziaWG';

  @override
  String get syncKindTt => 'TrustTunnel endpoint';

  @override
  String get syncKindOperation => 'Состояние сервера и операций';

  @override
  String get syncKindProfile => 'История профиля';

  @override
  String get syncKindWorkspace => 'Рабочее пространство';

  @override
  String syncRejectedCount(int count) {
    return 'Отклонённых групп с нарушенной историей изменений: $count. Рабочие данные сохранены.';
  }

  @override
  String get googleAccountTitle => 'Аккаунт Google';

  @override
  String get googleAccountHelp =>
      'Войдите в Google, чтобы подключить Google Drive.';

  @override
  String get googleSignIn => 'Войти в Google';

  @override
  String get googleSwitchAccount => 'Сменить аккаунт';

  @override
  String get googleSignOut => 'Выйти';

  @override
  String get googleConnected => 'Google Drive подключён.';

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
  String get autoSyncHelp =>
      'После сохранения, при открытии и каждые 30 секунд, пока приложение на экране.';

  @override
  String get autoSyncDisabled => 'Автосинхронизация выключена.';

  @override
  String get autoSyncWaiting => 'Изменения ожидают обмена.';

  @override
  String get autoSyncWorking => 'Обмен с Google Drive…';

  @override
  String get autoSyncDone => 'Обмен с Google Drive завершён.';

  @override
  String get autoSyncEditing =>
      'Данные получены. Закройте редактор сервера и перейдите в настройки или список серверов для применения. Текущие операции должны завершиться.';

  @override
  String get autoSyncConflict =>
      'Получены разные версии. Выберите нужную в разделе конфликтов ниже.';

  @override
  String get autoSyncIncomplete =>
      'Часть данных ожидает связанных изменений или не прошла проверку. Проверьте раздел конфликтов.';

  @override
  String get autoSyncError =>
      'Не удалось завершить обмен. Данные сохранены; приложение повторит попытку автоматически.';

  @override
  String get autoSyncNow => 'Синхронизировать сейчас';

  @override
  String autoSyncLast(String time) {
    return 'Последний обмен: $time';
  }

  @override
  String get autoSyncPairing =>
      'Подключение второго устройства: экспортируйте зашифрованную копию с основного устройства и восстановите её здесь в разделе «Резервные копии» ниже. Затем войдите в тот же Google-аккаунт. Один вход в Google не переносит ключ шифрования. Передавайте копию только доверенным устройствам. Обмен работает при открытом приложении.';

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
  String get autoSyncOtherWorkspaces =>
      'В Drive есть другое рабочее пространство. Чтобы получить его серверы и клиентов здесь, восстановите зашифрованную копию с устройства, где они уже есть.';

  @override
  String get publicationTitle => 'Публикация профилей';

  @override
  String get publicationHelp =>
      'Автоматически сохранять клиентские YAML в Google Drive и обновлять тот же файл. Настройте папку на одном устройстве, затем синхронизируйте остальные.';

  @override
  String get publicationAuthorize => 'Разрешить публикацию в Drive';

  @override
  String get publicationAuthorizeHelp =>
      'Для публикации подтвердите доступ к файлам приложения в Google. Синхронизация использует отдельное разрешение.';

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
  String get publicationCopyLink => 'Копировать ссылку профиля';
}
