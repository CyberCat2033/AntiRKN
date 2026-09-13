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
  String get templates => 'Шаблоны';

  @override
  String get settings => 'Настройки';

  @override
  String get workbench => 'Проверка базового профиля';

  @override
  String get prototype => 'Прототип P0';

  @override
  String get intro =>
      'Проверьте, какие узлы попадут в группы вашего шаблона. Изменения редактора остаются в памяти до закрытия приложения.';

  @override
  String get source => 'Базовый YAML';

  @override
  String get sourceHelp =>
      'Выберите .yml или .yaml через файловый диалог. Приложение работает с копией в памяти; исходный файл не изменяется.';

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
      'Прототип включает проверку шаблонов и тестовый каталог адресов одного VPS. Управление по SSH, хранилище секретов и синхронизация Google Drive ожидают следующих итераций.';

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
      'Системное отключение анимаций имеет приоритет. Настройки прототипа действуют до закрытия приложения.';

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
      'Пустая группа: перед публикацией нужно выбрать политику.';

  @override
  String get diagnosticChainHasExtraNodes =>
      'Proxy_Chain содержит узлы, исключённые из RemoteBalancer.';

  @override
  String get diagnosticUnreferencedGroup =>
      'На WG_Auto не ссылаются другие группы и правила.';

  @override
  String get diagnosticBaseContainsProxies =>
      'В шаблоне уже есть прокси. Нужен отдельный выбор способа импорта.';

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
    return 'Загружен в память: $name';
  }

  @override
  String get templateReadError =>
      'Не удалось прочитать YAML-файл. Текущий шаблон сохранён.';

  @override
  String get server => 'Сервер';

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
  String get sshSaved => 'Подключение сохранено в зашифрованном хранилище.';

  @override
  String get sshConnect => 'Сохранить и подключиться';

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
      'Удалить сохранённые секреты и доверенный ключ сервера с этого устройства? Настройки сервера не изменятся.';

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
  String get vaultTitle => 'Защищённое хранилище';

  @override
  String get vaultIntro =>
      'Сохраняйте данные входа SSH и доверие к серверу зашифрованными на этом устройстве. Выберите способ разблокировки.';

  @override
  String get vaultSystem => 'Использовать хранилище ОС';

  @override
  String get vaultMaster => 'Использовать мастер-пароль';

  @override
  String get vaultMasterHelp =>
      'Не менее 12 символов. Запомните пароль: он не сохраняется, сбросить его для восстановления данных нельзя. Этот вариант работает и без keyring Linux.';

  @override
  String get vaultPassword => 'Мастер-пароль';

  @override
  String get vaultConfirmation => 'Повторите мастер-пароль';

  @override
  String get vaultCreate => 'Создать зашифрованное хранилище';

  @override
  String get vaultUnlock => 'Разблокировать';

  @override
  String get vaultLock => 'Заблокировать хранилище';

  @override
  String get vaultLocked =>
      'Хранилище заблокировано. Разблокируйте для работы с сохранёнными подключениями.';

  @override
  String get vaultUnlocked => 'Хранилище разблокировано';

  @override
  String get vaultAutoLock =>
      'Блокируется после 5 минут бездействия и при переходе приложения в фон; SSH-соединения закрываются.';

  @override
  String get vaultWorking => 'Открытие хранилища…';

  @override
  String get vaultRetry => 'Повторить';

  @override
  String get vaultUnavailable =>
      'Системное хранилище недоступно. Разблокируйте keyring ОС и повторите попытку. Для нового хранилища можно выбрать мастер-пароль.';

  @override
  String get vaultMissingKey =>
      'Системный ключ шифрования недоступен. Для разблокировки восстановите доступ к исходному keyring ОС.';

  @override
  String get vaultDamaged =>
      'Неверный мастер-пароль или повреждённое хранилище. Сохранённые данные не изменены.';

  @override
  String get vaultCorrupt =>
      'Хранилище повреждено или имеет неподдерживаемый формат. Его файл сохранён.';

  @override
  String get vaultWriteFailed =>
      'Не удалось сохранить. Предыдущая сохранённая версия оставлена.';

  @override
  String get vaultBusy =>
      'Хранилище занято или изменено другим экземпляром приложения. Заблокируйте и разблокируйте его перед повторной попыткой.';

  @override
  String get vaultExists =>
      'Хранилище уже существует. Разблокируйте существующее.';

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
      'UID и наличие sudo — сведения текущего сеанса. Повышение прав для установки не проверялось.';

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
}
