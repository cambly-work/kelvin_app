# План реализации: единый privileged service, helpers и демоны

## Цель

Переработать привилегированные функции Kelvin так, чтобы:

- пользователь один раз осознанно устанавливал/одобрял системный компонент;
- обычные разрешённые действия выполнялись без повторного ввода пароля;
- не требовалось запускать shell-скрипты вручную;
- установка, обновление, диагностика и удаление были доступны из UI;
- root-компонент имел узкий типизированный API, а не возможность выполнить произвольную команду;
- при сбое или несовместимости система возвращалась в безопасное состояние.

Примеры функций:

- fan profiles и fan safety;
- charge limit;
- `powermetrics`;
- системный firewall;
- Kelvin-managed hosts blocklist;
- переключение `pmset gpuswitch` на поддерживаемых Intel dual-GPU Mac;
- другие будущие privileged actions.

## Честное ожидание для UX

Нельзя гарантировать «пароль никогда не появится». macOS может потребовать:

- подтверждение установки системного сервиса;
- одобрение в Login Items/System Settings;
- повторное одобрение после изменения подписи/идентификатора;
- восстановление повреждённой установки;
- удаление системного компонента.

Цель: одно понятное одобрение при установке и отсутствие пароля для каждой штатной операции после этого.

## Текущее состояние

Привилегированные действия фрагментированы:

- `Sources/HelperInstall.swift` запускает bundled shell installer через AppleScript admin prompt.
- `helper/install-helper.sh` ставит root `powerd`.
- `helper/install-fan-helper.sh` ставит root `fand`.
- uninstall выполняется отдельными shell-скриптами.
- `Sources/GPUInfo.swift` вызывает `osascript` для каждого `pmset gpuswitch`.
- `Sources/Firewall.swift`, `Sources/HostBlock.swift`, `Sources/SecurityTools.swift` имеют собственные admin-shell пути.
- `uninstall-app.sh` оставляет пользователю ручные команды для части компонентов.
- Статус установки часто определяется только существованием plist, а не реальным health/identity процесса.

Результат:

- повторные password prompts;
- несколько механизмов авторизации;
- shell quoting и injection surface;
- сложно обновлять версии демонов;
- сложно объяснить состояние пользователю;
- удаление не полностью централизовано.

## Целевая архитектура

```text
Kelvin.app (user)
   ↓ typed XPC requests
KelvinPrivilegedService (root, launchd/ServiceManagement)
   ├── FanControllerService
   ├── ChargeControllerService
   ├── PowerMetricsService
   ├── FirewallService
   ├── HostBlockService
   └── GPUModeService
```

Главный принцип: один установленный сервис, много строго разрешённых операций.

Не делать API:

```swift
run(command: String)
run(path: String, arguments: [String])
executeShell(script: String)
```

Делать API уровня намерений:

```swift
setFanProfile(_ profile: ValidatedFanProfile)
restoreFansAutomatic()
setChargeLimit(_ percent: Int)
setFirewallEnabled(_ enabled: Bool)
setFirewallRule(_ rule: ValidatedFirewallRule)
applyHostBlocklist(_ domains: [ValidatedDomain])
setGPUMode(_ mode: GPUMode)
readPowerMetrics()
getStatus()
```

## Выбор системного механизма

Агент должен провести короткий design spike для двух веток ОС:

### Современные macOS

Предпочесть ServiceManagement API для регистрации launch daemon/helper с системным одобрением и XPC.

Проверить:

- доступный API для текущего deployment target;
- требования к bundle layout/plist;
- code-signing requirements;
- user approval flow;
- поведение update/re-register;
- статус и удаление.

### macOS 11–12

Выбрать явно:

1. поддерживаемый legacy blessed-helper путь;
2. сохранение текущего install prompt только как compatibility fallback;
3. повышение минимальной версии Kelvin.

Не смешивать legacy и modern paths без единого facade/state model.

Решение о минимальной ОС должно быть продуктовым и задокументированным.

## Этап 1. Инвентаризация privileged operations

Составить таблицу по всем операциям:

| Операция | Сейчас | Нужен root | Риск | Новый API |
|---|---|---:|---|---|
| Fan profile | `fand` + JSON | да | высокий | `setFanProfile` |
| Charge limit | `fand` config | да | высокий | `setChargeLimit` |
| Power metrics | `powerd` shell | да | средний | stream/snapshot |
| GPU mode | `osascript pmset` | да | средний | `setGPUMode` |
| Firewall | admin shell | да | высокий | typed firewall calls |
| Hosts block | root script | да | высокий | validated domains |
| Gatekeeper | admin shell | да | очень высокий | отдельное решение |
| Clear quarantine | иногда | условно | высокий | возможно не переносить |

Для каждой операции определить:

- нужна ли она продукту;
- должна ли она входить в единый service;
- безопасный allowlist;
- rollback;
- поддерживаемые модели/версии macOS.

Особенно пересмотреть функции отключения Gatekeeper: удобство не оправдывает автоматическое снижение системной защиты. Рекомендуемый вариант — не включать такие операции в постоянный root service.

## Этап 2. Protocol и version handshake

Создать общий protocol definitions модуль, доступный app и service:

```text
Sources/PrivilegedProtocol.swift
```

Все request/response:

- `Codable` или `NSSecureCoding`;
- versioned;
- с ограниченными enum/value types;
- без произвольных путей и команд;
- с machine-readable error codes.

Handshake:

```swift
struct ServiceInfo {
    let serviceVersion: String
    let protocolVersion: Int
    let supportedCapabilities: Set<Capability>
    let health: ServiceHealth
}
```

App не вызывает несовместимую capability.

## Этап 3. Проверка клиента XPC

Root service обязан проверять подключившийся клиент:

- audit token;
- code signature;
- bundle identifier;
- Team ID/designated requirement;
- protocol version.

Нельзя доверять запросу только потому, что он пришёл через локальный XPC endpoint.

При invalid client:

- отказ;
- безопасный audit log без пользовательских данных;
- никакого partial action.

## Этап 4. Разделить постоянные и разовые обязанности

### Постоянный service

- применяет fan/charge policy;
- поддерживает lease/watchdog;
- отдаёт power metrics;
- выполняет типизированные system changes;
- сообщает health.

### App

- хранит пользовательский UI state;
- валидирует ввод для удобных ошибок;
- отправляет уже нормализованные intent requests;
- показывает результат;
- не пишет root-owned файлы напрямую.

### Конфигурация

Не читать root-демоном произвольный JSON из user-writable пути как доверенную команду.

Предпочтительно:

- XPC update config;
- service повторно валидирует данные;
- service хранит root-owned atomic config;
- app получает sanitized current state через XPC.

Если user-writable transport временно сохраняется для миграции, он считается недоверенным.

## Этап 5. Безопасный API по подсистемам

### Fan/charge

- диапазоны RPM/temperature/charge limit валидируются service;
- разрешённые SMC-ключи приходят из проверенного resolver/mapping;
- lease от app;
- watchdog;
- при истечении lease:
  - fans → auto;
  - charge → безопасная документированная политика;
- аварийный перегрев имеет приоритет над пользовательским профилем;
- fanless/unsupported устройство получает `unsupported`, а не ошибку установки.

### Power metrics

- service запускает только фиксированный executable `/usr/bin/powermetrics`;
- фиксированный allowlist аргументов;
- контролируемый timeout;
- bounded output;
- парсинг без shell;
- отдавать структурированные числа, не raw text.

### GPU switching

- capability доступна только если:
  - Intel;
  - минимум две GPU;
  - `pmset gpuswitch` реально поддерживается;
- service вызывает `/usr/bin/pmset` напрямую с фиксированными args;
- mode только enum `0/1/2`;
- UI показывает совместимость до попытки;
- после запроса перечитать фактический mode;
- больше не запускать AppleScript password prompt на каждое переключение.

### Firewall

- фиксированный binary path;
- typed operations;
- validate app path:
  - absolute;
  - существующий `.app`;
  - canonicalized;
  - без shell;
- сериализовать изменения;
- перечитать фактическое состояние после операции.

### Hosts blocklist

- принимать массив нормализованных доменов;
- строгая проверка DNS-name;
- лимиты числа/длины;
- root service атомарно меняет только Kelvin-marked section;
- сохраняет backup/rollback;
- не принимает путь к пользовательскому файлу.

### Опасные security toggles

Gatekeeper disable и массовое снятие quarantine рассмотреть отдельно. Не давать постоянному сервису универсальную возможность ослаблять защиту системы без дополнительного явного подтверждения на каждое опасное действие.

## Этап 6. Installation Coordinator и UX

Новый facade:

```text
Sources/PrivilegedServiceManager.swift
```

Состояния:

```swift
enum PrivilegedServiceState {
    case notInstalled
    case approvalRequired
    case installing
    case healthy(ServiceInfo)
    case updateRequired
    case incompatible
    case degraded(reason: ServiceFailure)
    case repairing
    case uninstalling
}
```

Единая карточка настроек:

- `Системные функции Kelvin`;
- список capabilities;
- статус;
- кнопка `Установить`/`Разрешить`/`Обновить`/`Исправить`/`Удалить`;
- объяснение до системного prompt:
  - зачем нужны права;
  - что именно сможет сервис;
  - как удалить;
- кнопка `Открыть системные настройки`, если требуется approval;
- живой health check.

Не просить пароль при случайном клике по каждому toggle. Если service отсутствует:

1. показать preflight sheet;
2. получить одно осознанное согласие;
3. пройти системную установку;
4. после health check применить исходное действие.

Если пользователь отменил, вернуть toggle в прежнее состояние без пугающего алерта.

## Этап 7. Миграция старых демонов

При первой успешной установке нового service:

- обнаружить старые labels:
  - `com.trykelvin.kelvin.powerd`;
  - `com.trykelvin.kelvin.fand`;
  - legacy `com.local.batterymeter.*`;
- прочитать совместимые пользовательские настройки;
- перевести fan/charge в безопасное состояние;
- остановить старые jobs;
- удалить старые plist/binaries;
- установить новый service;
- импортировать валидную конфигурацию;
- подтвердить health;
- записать migration marker.

Миграция должна быть идемпотентной.

При сбое:

- не оставлять одновременно два fan controller;
- fans → auto;
- понятная кнопка retry;
- диагностический код.

## Этап 8. Обновление service

Service обновляется только подписанным и проверенным приложением.

Проверять:

- Team ID;
- bundle ID;
- code requirement;
- protocol compatibility;
- staged replacement;
- health новой версии.

Не копировать executable из group/other-writable bundle.

Если приложение запущено из Downloads:

- предложить переместить в `/Applications`;
- не устанавливать root service из небезопасного расположения.

## Этап 9. Удаление

В UI должна быть одна кнопка `Удалить системный компонент`.

Процесс:

1. вернуть fans auto;
2. снять/нормализовать charge policy;
3. откатить только Kelvin-managed firewall/hosts state согласно выбранной политике;
4. остановить service;
5. unregister;
6. удалить root-owned Kelvin files;
7. проверить отсутствие jobs/processes;
8. сохранить понятный результат.

`uninstall-app.sh` обновить:

- не требовать ручного набора нескольких команд;
- либо вызывать официальный uninstaller;
- либо объяснять один системный шаг для orphaned service, если app уже удалено.

Нельзя удалять не-Kelvin правила пользователя.

## Этап 10. Логи и диагностика

Service использует unified logging:

- subsystem `com.trykelvin.kelvin`;
- отдельные categories;
- без профилей, доменов и пользовательских путей в public fields;
- bounded diagnostics.

Диагностический отчёт:

- installation state;
- service version/protocol;
- capabilities;
- last health check;
- last safe error code;
- launchd state;
- не содержит root secrets или произвольный raw log.

## Этап 11. Тесты безопасности

### Unit

- validation каждого request;
- invalid enum/range/path/domain;
- protocol mismatch;
- lease expiry;
- fan safety;
- charge rollback;
- migration state machine;
- installation state machine.

### XPC/security

- неподписанный клиент отвергается;
- другой Team ID отвергается;
- spoofed bundle ID отвергается;
- malformed payload;
- oversized payload;
- replay/idempotency;
- concurrent conflicting requests;
- service crash mid-operation.

### Integration

- fresh install;
- user cancels;
- approval required;
- install succeeds;
- old daemons migrate;
- service update;
- app update with compatible/incompatible service;
- service unavailable;
- uninstall;
- app forcibly killed;
- reboot;
- multiple macOS versions.

### Hardware

- M1 Air fanless;
- Apple Silicon Mac с вентиляторами;
- Intel single-GPU;
- Intel dual-GPU с `gpuswitch`;
- Mac без батареи.

## Этап 12. Порядок внедрения

Не переносить всё одним релизом.

1. Service skeleton + status/handshake, без mutations.
2. Power metrics.
3. GPU switching.
4. Fan/charge с отдельным hardware QA.
5. Hosts blocklist.
6. Firewall.
7. Миграция/удаление старых демонов.
8. Удаление старых `osascript` путей.

Fan/charge переносятся только после проверки watchdog и rollback.

## Рекомендуемые коммиты

1. `docs: inventory privileged operations and risks`
2. `feat: add versioned privileged xpc protocol`
3. `feat: add service installation coordinator`
4. `feat: move power metrics behind service`
5. `feat: move gpu switching behind typed service api`
6. `feat: migrate fan and charge control`
7. `feat: migrate firewall and host block operations`
8. `feat: add legacy daemon migration and uninstall`
9. `test: harden xpc authorization and rollback`
10. `docs: document service approval and recovery`

## Definition of Done

- После однократной установки/одобрения штатные операции не требуют повторного пароля.
- GPU switching не запускает ручной script/AppleScript на каждый выбор.
- Нет универсального root shell API.
- Root service проверяет подпись клиента.
- App и service имеют version handshake.
- Fan/charge имеют watchdog и безопасный rollback.
- Установка, repair, update и uninstall доступны из UI.
- Старые демоны мигрируются идемпотентно и не работают параллельно.
- Диагностика объясняет состояние человеческим языком.
- Есть проверенный fallback или официальное решение по macOS 11–12.
- Пройдены security tests и hardware QA.

