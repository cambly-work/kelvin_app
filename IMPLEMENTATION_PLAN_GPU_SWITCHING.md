# План реализации: переключение графики из Kelvin без повторного пароля

## Результат

На поддерживаемом Intel Mac с двумя внутренними GPU пользователь:

- видит текущую активную видеокарту и выбранную системную политику;
- выбирает `Авто`, `Встроенная` или `Дискретная` прямо в Kelvin;
- при желании задаёт разные режимы для питания от сети и батареи;
- один раз подключает системный компонент;
- после подключения переключает режимы без повторного запроса пароля.

На Apple Silicon, Intel Mac с одной GPU и неподдерживаемых конфигурациях Kelvin
остаётся в read-only режиме и честно объясняет, почему переключение недоступно.

Важно: полностью исключить системное подтверждение нельзя. macOS вправе запросить
однократное одобрение при установке, обновлении, восстановлении или удалении
привилегированного сервиса. Штатное переключение после успешной установки не
должно показывать пароль или отправлять пользователя в системные настройки.

## Текущее состояние

- `Sources/GPUInfo.swift` уже:
  - перечисляет GPU через Metal;
  - показывает активную GPU главного дисплея;
  - читает `pmset gpuswitch`;
  - содержит тип `GPUMode` со значениями `0/1/2`.
- `GPUInfo.setMode` запускает `osascript` с administrator privileges, поэтому
  каждое изменение может вызывать запрос пароля.
- В новой панели `Sources/NewSettings.swift` кнопка `Открыть настройки` уводит
  пользователя в настройки macOS.
- В истории репозитория уже есть in-app Picker и переключатель в popover. Их
  можно вернуть после замены привилегированного transport-слоя.
- В проекте есть установка root-демонов для вентиляторов и `powermetrics`, но
  нет безопасного XPC API для GPU.

## Граница MVP

В первый релиз входят:

1. безопасный системный service с одной GPU capability;
2. ручное переключение из окна настроек и popover;
3. однократный setup/approval flow;
4. режимы по источнику питания;
5. диагностика, удаление и hardware QA.

Не входят:

- произвольный запуск команд от root;
- переключение GPU на Apple Silicon;
- управление отдельными приложениями, которые удерживают discrete GPU;
- одновременная миграция firewall, hosts, fan и charge на новый API.

Service проектируется как основа будущего `KelvinPrivilegedService`, но GPU
остаётся первой изолированной capability.

## Целевая архитектура

```text
SwiftUI Settings / AppKit popover
              |
              | intent: setGPUMode(.automatic/.integratedOnly/.discreteOnly)
              v
GPUController + PrivilegedServiceClient
              |
              | typed XPC, version handshake, client identity verification
              v
KelvinPrivilegedService (root, launchd)
              |
              | fixed executable + fixed validated arguments, no shell
              v
/usr/bin/pmset -> read-back of actual policy -> structured result
```

`GPUInfo` остаётся слоем обнаружения и чтения hardware state. Привилегированную
запись из него нужно удалить.

Запрещённый API:

```swift
runCommand(_ command: String)
run(_ executable: String, arguments: [String])
executeShell(_ script: String)
```

Разрешённый API:

```swift
getServiceInfo(reply:)
getGPUMode(reply:)
setGPUMode(_ rawMode: Int, requestID: UUID, reply:)
```

На стороне service `rawMode` повторно преобразуется в закрытый enum. Принимаются
только значения `0`, `1`, `2`.

## Шаг 0. Зафиксировать платформенное решение

Сейчас Kelvin собирается с deployment target macOS 11. Перед реализацией нужно
выбрать и задокументировать один вариант:

### Вариант A — сохранить macOS 11–12

- macOS 13+:
  - `SMAppService.daemon(plistName:)`;
  - daemon plist внутри `Contents/Library/LaunchDaemons`;
  - регистрация из Kelvin;
  - если статус `requiresApproval`, одна понятная CTA открывает системную панель
    только для первоначального одобрения.
- macOS 11–12:
  - legacy blessed-helper flow через `SMJobBless`;
  - тот же XPC protocol и тот же `PrivilegedServiceManager`;
  - один authorization prompt при установке, не при GPU action.

### Вариант B — поднять minimum OS до macOS 13

- один современный `SMAppService` flow;
- меньше установочного и тестового кода;
- прекращение поддержки текущих пользователей на macOS 11–12.

Рекомендуемый вариант: A, если статистика активных установок оправдывает
поддержку macOS 11–12; иначе B. Не оставлять два механизма без единого facade и
общей state machine.

Текущий shell-installer можно использовать только как временный development
fallback. Он не должен оставаться единственным production-механизмом установки
нового XPC service.

## Шаг 1. Вынести чистую GPU-модель

Создать тестируемые типы без AppKit/Process:

```swift
enum GPUMode: Int, CaseIterable {
    case integratedOnly = 0
    case discreteOnly = 1
    case automatic = 2
}

enum GPUSupportState: Equatable {
    case supported
    case appleSilicon
    case singleGPU
    case externalGPUOnly
    case pmsetUnsupported
    case unknown
}
```

Усилить capability detection:

- CPU architecture — Intel;
- есть внутренняя low-power GPU;
- есть внутренняя discrete GPU;
- eGPU сама по себе не делает Mac switchable;
- `pmset` действительно возвращает `gpuswitch`;
- mode парсится только как `0/1/2`.

Разделить:

- выбранную политику `GPUMode`;
- реально активную видеокарту `GPUInfo.active()`.

Они не обязаны совпадать мгновенно: приложение или внешний монитор могут
удерживать discrete GPU даже при политике `Авто` или `Встроенная`.

## Шаг 2. Добавить versioned XPC protocol

Новые файлы:

```text
Sources/PrivilegedProtocol.swift
Sources/PrivilegedServiceClient.swift
Sources/PrivilegedServiceManager.swift
helper/privileged/main.swift
helper/privileged/com.trykelvin.kelvin.privileged.plist
```

Handshake должен возвращать:

```swift
struct PrivilegedServiceInfo {
    let serviceVersion: String
    let protocolVersion: Int
    let capabilities: Set<PrivilegedCapability>
    let health: ServiceHealth
}
```

Минимальные состояния manager:

```swift
enum PrivilegedServiceState {
    case notInstalled
    case approvalRequired
    case installing
    case healthy(PrivilegedServiceInfo)
    case updateRequired
    case incompatible
    case repairNeeded
    case unavailable
}
```

Требования к соединению:

- service проверяет audit identity подключившегося процесса;
- проверяет code signature/designated requirement;
- разрешает только bundle id `com.trykelvin.kelvin`;
- проверяет Team ID production-подписи;
- app проверяет version/identity service и не доверяет неизвестному Mach endpoint;
- проверяет protocol version;
- при Fast User Switching принимает mutation только от Kelvin активного console
  user;
- отклоняет неподписанный, подменённый и несовместимый клиент до выполнения
  любой команды.

`AppConfig.expectedDeveloperTeamID` сейчас не заполнен. Настроенная Developer ID
подпись, Team ID и notarization являются release blocker для production
privileged service. Ad-hoc сборка допустима только для явно отделённого local
development режима.

## Шаг 3. Реализовать GPU capability в service

Алгоритм `setGPUMode`:

1. проверить identity клиента и protocol version;
2. проверить hardware capability;
3. преобразовать вход в закрытый `GPUMode`;
4. сериализовать запросы на отдельной очереди;
5. запустить только:

   ```text
   /usr/bin/pmset -a gpuswitch <0|1|2>
   ```

6. не использовать shell, AppleScript и пользовательские пути;
7. применить timeout и ограничить размер stdout/stderr;
8. перечитать состояние через фиксированный `/usr/bin/pmset -g`;
9. вернуть подтверждённый mode или машинно-читаемую ошибку.

Ошибки:

```swift
enum GPUModeError {
    case unsupportedHardware
    case invalidMode
    case unauthorizedClient
    case protocolMismatch
    case serviceUnavailable
    case commandTimedOut
    case pmsetFailed(code: Int)
    case verificationFailed(expected: GPUMode, actual: GPUMode?)
}
```

Каждый request получает `requestID`. Повтор одного завершённого request не
должен создавать конфликтующее действие. Быстрые клики сериализуются, а UI
блокирует selector до read-back.

## Шаг 4. Сборка, подпись и установка

Обновить:

- `build.sh`:
  - собрать universal helper для `x86_64` и `arm64`;
  - положить его в правильную bundle-структуру;
  - включить launchd plist/Mach service metadata;
  - подписать вложенный executable до подписи главного app bundle.
- `release.sh`:
  - подписать helper и app одной Developer ID identity;
  - проверить designated requirements;
  - notarize итоговый bundle;
  - fail closed, если Team ID для client validation не настроен.
- `Info.plist` и helper metadata:
  - добавить только записи, требуемые выбранным ServiceManagement flow;
  - не добавлять универсальные privileged rights.

Обновление app не должно незаметно оставлять устаревший service. При старте новой
версии manager сравнивает версии, выполняет re-register/update только через
явный системный flow и не пытается обновлять helper во время GPU-переключения.

Установочный UX:

1. Kelvin проверяет, что production app находится в `/Applications`; при запуске
   с DMG/Downloads сначала предлагает безопасно переместить приложение;
2. пользователь выбирает режим или включает автоматику;
3. если service отсутствует, selector не запускает пароль сам;
4. Kelvin показывает sheet:
   - зачем нужен компонент;
   - что он умеет только переключать разрешённые GPU modes;
   - что одобрение требуется один раз;
   - где компонент удалить;
5. после явного `Подключить` запускается системный install/approval flow;
6. Kelvin ждёт healthy handshake;
7. исходный intent повторяется один раз;
8. при отмене UI возвращается к фактическому mode без пугающего alert.

Install, update, repair и uninstall должны быть явными действиями. Обычный
Picker никогда не должен неожиданно открывать password prompt.

## Шаг 5. Вернуть ручное переключение в UI

### Окно настроек

В `Sources/NewSettings.swift` заменить `Открыть настройки` на:

- текущую активную GPU;
- текущую политику;
- Picker `Авто / Встроенная / Дискретная`;
- inline состояние `Применяется…`;
- статус системного компонента и явную setup CTA при необходимости.

### Popover

В `Sources/main.swift` вернуть компактный `PillTabBar`:

- `Встроенная`;
- `Дискретная`;
- `Авто`.

Сохранить уже существующее разделение:

- строка сверху показывает реально активную GPU;
- selector показывает политику `pmset`.

### Поведение

- все чтения `pmset` и XPC calls выполняются вне main thread;
- selector временно disabled во время запроса;
- повторный выбор текущего mode ничего не запускает;
- после успеха selector принимает только подтверждённое read-back значение;
- при ошибке возвращается прежнее фактическое значение;
- показывается короткая понятная ошибка с действием `Повторить` или
  `Восстановить компонент`;
- Pro-проверка выполняется до setup flow;
- предупреждение о flicker/нагреве показывается только перед первым выбором
  принудительного режима, а не при каждом переключении;
- `Авто` всегда остаётся быстрым способом вернуться к системной политике.

`Открыть системные настройки` оставить только как fallback для первоначального
approval/диагностики, а не как основной GPU control.

## Шаг 6. Добавить автоматику по источнику питания

Настройки:

```swift
gpuAutomationEnabled: Bool
gpuModeAC: GPUMode
gpuModeBattery: GPUMode
```

Безопасные значения по умолчанию:

- автоматика выключена;
- сеть — `Авто`;
- батарея — `Встроенная`.

UX:

- toggle `Автоматически по источнику питания`;
- два Picker: `На сети` и `На батарее`;
- текст о том, что внешний дисплей или приложение могут удерживать discrete GPU;
- при включении автоматики Kelvin один раз применяет режим текущего источника;
- ручной выбор считается override до следующей реальной смены источника.

Контроллер:

- вынести общий power-source edge monitor из существующей fan automation;
- реагировать на plug/unplug и wake;
- debounce 2–3 секунды, чтобы не переключаться на дребезге питания;
- не отправлять запрос, если нужный mode уже активен;
- использовать generation/request ID, чтобы старый ответ не перезаписал новый;
- при недоступном service сохранить policy, но показать `Ожидает подключения`,
  не запрашивая пароль в фоне;
- после восстановления соединения один раз сверить и применить режим текущего
  источника.

Отдельный hardware spike:

- проверить на реальном dual-GPU Mac работу `pmset -b gpuswitch …` и
  `pmset -c gpuswitch …`;
- если macOS надёжно хранит и применяет обе политики, добавить типизированный
  `setGPUPowerPolicy(ac:battery:)` и позволить системе переключать режим даже
  когда Kelvin закрыт;
- если поведение отличается по моделям/macOS, оставить app-side edge monitor и
  прямо написать в UI, что автоматика работает, пока Kelvin запущен.

Недокументированное или нестабильное поведение `pmset` нельзя считать
поддержанным без hardware matrix.

## Шаг 7. Миграция старого пути

После успешного rollout:

- удалить privileged реализацию `GPUInfo.setMode` через `osascript`;
- запретить новые вызовы `with administrator privileges` для GPU;
- обновить тексты, где сказано, что пароль нужен при каждом переключении;
- не передавать GPU intent через user-writable JSON существующего `fand`;
- не связывать доступность GPU switching с установленным fan helper;
- при будущем объединении сервисов сохранить protocol/capability boundary.

Удаление системного компонента:

1. перед первой Kelvin-mutation сохранить исходные значения GPU policy в
   root-owned state;
2. при удалении предложить восстановить исходную policy или оставить текущую;
3. дождаться подтверждённого read-back выбранного варианта;
4. unregister service;
5. проверить, что launchd job и XPC endpoint исчезли;
6. не удалять пользовательские данные других подсистем.

## Карта изменений по файлам

| Файл | Изменение |
|---|---|
| `Sources/GPUInfo.swift` | оставить detect/read, удалить privileged AppleScript write |
| `Sources/PrivilegedProtocol.swift` | versioned типы, capability и ошибки |
| `Sources/PrivilegedServiceClient.swift` | XPC connection, timeout, reconnect |
| `Sources/PrivilegedServiceManager.swift` | install/approval/health/update state machine |
| `Sources/AppConfig.swift` | обязательный production Team ID |
| `Sources/SettingsCoordinator.swift` | единая явная setup/repair/uninstall CTA |
| `Sources/Settings.swift` | настройки GPU automation для AC/battery |
| `Sources/NewSettings.swift` | in-app Picker, setup и busy/error states |
| `Sources/main.swift` | popover selector и общий power-source monitor |
| `helper/privileged/*` | root service, client validation, фиксированный `pmset` |
| `build.sh`, `release.sh`, `Info.plist` | bundle layout, подпись, ServiceManagement metadata |
| `Sources/Localization.swift` | новые и исправленные строки RU/UK/EN/PT |
| `test/units/*`, `QA.md` | unit gate и ручная hardware matrix |

## Шаг 8. Тесты

### Unit

- парсинг `pmset` для `0/1/2`, отсутствующего и повреждённого значения;
- capability detection:
  - Intel dual internal GPU;
  - Intel single GPU;
  - Intel + eGPU;
  - Apple Silicon;
- validation enum и protocol version;
- automation state machine:
  - enable;
  - AC → battery;
  - battery → AC;
  - debounce;
  - duplicate event;
  - stale response;
  - manual override;
- UI rollback после ошибки/cancel.

Для тестов command runner должен быть injectable; unit-тесты не запускают
настоящий `pmset` и не требуют root.

### XPC/security

- неподписанный клиент отвергается;
- неверный bundle ID/Team ID отвергается;
- app отвергает service с неверной identity/version;
- несовместимая версия отвергается;
- invalid/oversized payload;
- параллельные requests;
- service crash между write и read-back;
- соединение от неактивного Fast User Switching session.

### Integration

- fresh install;
- пользователь отменил approval;
- approval завершён;
- service update/repair;
- app update с совместимым и несовместимым protocol;
- повторные переключения не показывают password prompt;
- reboot, wake, logout/login;
- uninstall возвращает безопасное состояние.

### Hardware

- Intel dual-GPU на поддерживаемых версиях macOS;
- AC и battery;
- приложения, удерживающие discrete GPU;
- внешний монитор;
- Intel single-GPU;
- Intel с eGPU;
- Apple Silicon;
- macOS 11–12, если они остаются поддерживаемыми;
- macOS 13+ через `SMAppService`.

## Порядок поставки

### Релиз A — безопасный manual MVP

1. чистая модель и тесты;
2. service skeleton + handshake;
3. client identity verification;
4. `setGPUMode` + read-back;
5. install/approval/repair state machine;
6. Picker в Settings и popover;
7. удалить per-switch AppleScript.

### Релиз B — автоматика

1. настройки AC/battery;
2. power-source monitor;
3. debounce/idempotency;
4. wake/reconnect;
5. аппаратная проверка per-source `pmset` policy.

### Релиз C — общее системное управление

- перенос следующих capabilities в тот же versioned service по отдельному
  плану `IMPLEMENTATION_PLAN_PRIVILEGED_SERVICES.md`;
- миграция старых `powerd/fand` только после отдельного hardware QA.

## Definition of Done

- Режим GPU выбирается в Settings и popover Kelvin.
- На штатном переключении не открываются системные настройки.
- После однократного setup обычное переключение не запрашивает пароль.
- Пароль/approval возможен только для install, update, repair или uninstall.
- Нет GPU-вызовов через privileged AppleScript или shell.
- Root service принимает только `GPUMode 0/1/2` и запускает фиксированный
  `/usr/bin/pmset`.
- Service проверяет подпись, bundle ID, Team ID и protocol version клиента.
- App проверяет identity/version подключённого service.
- UI отдельно показывает policy и реально активную GPU.
- Результат каждого изменения подтверждается read-back.
- Автоматика AC/battery не создаёт повторных запросов и корректно переживает
  wake/reconnect.
- Apple Silicon, single-GPU и eGPU-only конфигурации не получают ложный control.
- Есть проверенный install/update/uninstall flow.
- Пройдены security tests и hardware QA на реальном Intel dual-GPU Mac.
