# План реализации: добровольные отчёты о сбоях разработчику

## Цель

Добавить приватный и понятный процесс отправки разработчику отчётов о падениях Kelvin:

- приложение локально обнаруживает собственный новый crash report;
- показывает человеку, что именно будет отправлено;
- отправляет только после явного согласия либо согласно отдельно включённой настройке;
- удаляет персональные данные и потенциально чувствительный контент;
- разработчик получает структурированный отчёт с версией, стеком и диагностическим контекстом;
- повторный запуск не отправляет один и тот же crash несколько раз.

## Текущее состояние

- `Sources/Maintenance.swift` читает `~/Library/Logs/DiagnosticReports` и строит сводку crash-файлов.
- `Sources/DiagnosticReport.swift` включает только количество/краткую строку, но ничего не отправляет.
- В privacy/marketing заявлена локальность и почти полное отсутствие сетевых запросов.
- Backend приёма crash reports в репозитории не обнаружен.

Следовательно, автоматическую отправку нельзя включать скрыто: это изменяет обещание приватности и сетевую модель продукта.

## Продуктовая политика

Рекомендуемый default:

- crash report обнаруживается локально;
- после следующего запуска появляется спокойная карточка:
  `Kelvin неожиданно завершил работу. Отправить обезличенный отчёт разработчику?`;
- действия:
  - `Посмотреть`;
  - `Отправить`;
  - `Не отправлять`;
- дополнительная настройка:
  `Автоматически отправлять обезличенные отчёты о сбоях`;
- по умолчанию автоматическая отправка выключена.

Не использовать dark patterns и не связывать отправку с лицензией.

## Неизменяемые требования приватности

Никогда не отправлять:

- полное содержимое `.ips` без санитизации;
- имя пользователя и домашний путь;
- серийный номер;
- hardware UUID;
- лицензионный ключ;
- email;
- IP, собранный приложением;
- содержимое буфера обмена;
- набранные слова автоязыка;
- пути и имена пользовательских документов;
- список открытых окон;
- произвольные логи shell-команд;
- SMC raw dump без отдельного показа/согласия.

Допустимые поля после проверки:

- schema version;
- anonymous installation ID, если он действительно нужен;
- app version/build;
- macOS version/build;
- `hw.model`;
- architecture;
- exception type/signal;
- termination reason;
- crashed thread frames;
- binary images только для Kelvin и системных Apple frameworks;
- наличие/версия Kelvin service;
- feature-state flags без содержимого;
- последние внутренние breadcrumbs из строгого allowlist;
- timestamp с ограниченной точностью.

IP неизбежно виден серверу на транспортном уровне. Политика сервера должна запрещать его сохранение либо задавать минимальный retention.

## Этап 1. Определить способ получения crash data

Перед реализацией сравнить:

1. Парсинг системных `.ips` после следующего запуска.
2. Встроенный crash SDK.
3. Собственный минимальный crash handler.

Не писать signal handler самостоятельно без серьёзной необходимости: async-signal-safe сбор падений сложен и легко создаёт дополнительные сбои.

Для текущего проекта естественный первый вариант — использовать уже обнаруживаемые `.ips`, но:

- читать только crash Kelvin;
- копировать/парсить после следующего запуска;
- не изменять системный файл;
- нормализовать данные в собственную allowlist-схему.

Если выбирается сторонний SDK, отдельно проверить:

- open-source статус;
- endpoint/self-hosting;
- какие данные SDK добавляет автоматически;
- offline queue;
- macOS compatibility;
- symbolication;
- возможность отключить attachments/session replay/analytics.

## Этап 2. Модель локального crash inbox

Новый компонент, например:

```text
Sources/CrashReportStore.swift
```

Задачи:

- найти только новые crash reports Kelvin;
- вычислить стабильный fingerprint локального файла;
- хранить состояния:
  - discovered;
  - reviewed;
  - consented;
  - queued;
  - sent;
  - declined;
  - expired;
- не отправлять duplicate;
- удалять локальные подготовленные payload через ограниченный срок.

Хранить metadata в:

```text
~/Library/Application Support/Kelvin/CrashReports/
```

Не копировать полный исходный `.ips`, если достаточно подготовленного санитизированного payload.

## Этап 3. Санитизатор с allowlist

Новый компонент:

```text
Sources/CrashReportSanitizer.swift
```

Использовать allowlist, а не бесконечный blacklist.

Pipeline:

```text
system .ips
  → parse
  → select allowed fields
  → normalize paths/addresses
  → remove user-controlled strings
  → cap sizes/counts
  → produce preview + JSON payload
```

Требования:

- заменить home path на `$HOME`;
- удалить аргументы командной строки и environment;
- ограничить число threads/frames/binary images;
- ограничить payload, например 256–512 KiB;
- не включать memory contents;
- не включать соседние crash reports других приложений;
- поддержать schema version.

Добавить golden tests с искусственными PII:

- `/Users/alice/Documents/secret.docx`;
- email;
- UUID;
- license-like token;
- Unicode username;
- shell arguments.

Тест обязан доказывать отсутствие этих строк в результате.

## Этап 4. Breadcrumbs

Если нужны события перед падением, создать кольцевой локальный журнал строгих enum-событий:

```swift
enum CrashBreadcrumb {
    case appStarted
    case popoverOpened
    case settingsOpened(section: SafeSection)
    case helperConnectionChanged(SafeConnectionState)
    case updateStateChanged(SafeUpdateState)
    case sensorAvailabilityChanged(SafeSensorState)
}
```

Запрещены произвольные строки и пользовательский ввод.

Хранить ограниченно:

- максимум 50–100 записей;
- без сетевых адресов;
- без названий файлов/окон;
- без набранных слов;
- с coarse timestamps.

## Этап 5. Preview и согласие

Карточка просмотра должна показывать:

- версия Kelvin;
- модель Mac и macOS;
- тип падения;
- стек Kelvin;
- безопасные breadcrumbs;
- точный endpoint;
- ссылку на privacy policy.

Кнопки:

- `Отправить`;
- `Скопировать`;
- `Сохранить в файл`;
- `Не отправлять`.

При автоматической отправке пользователь всё равно должен иметь:

- настройку выключения;
- список последних отправок;
- возможность открыть санитизированный payload;
- понятный retention-текст.

## Этап 6. Backend приёма

Нужен отдельный HTTPS endpoint, например:

```text
POST /api/v1/crash-reports
Content-Type: application/json
```

Сервер обязан:

- принимать только известную schema version;
- иметь строгий max body size;
- rate limit;
- не исполнять/рендерить недоверенный Markdown/HTML;
- выдавать opaque report ID;
- минимизировать access logs;
- иметь retention policy;
- шифровать transport и storage;
- не требовать лицензионный ключ;
- отделять crash reporting от аналитики.

Минимальная защита от мусора:

- app/build metadata validation;
- per-install rate limit без устойчивого tracking ID, если возможно;
- server-side deduplication по crash fingerprint;
- abuse monitoring.

Не встраивать секрет API в клиент: секрет из `.app` извлекается. Клиентский endpoint должен быть безопасен без скрытого секрета.

## Этап 7. Symbolication

Для каждого release:

- архивировать dSYM;
- привязать dSYM к build number и UUID бинаря;
- не публиковать приватные signing credentials;
- автоматически символицировать отчёты на backend/в закрытом developer pipeline;
- проверять, что UUID отчёта совпадает с архивным dSYM.

Обновить `release.sh`/CI:

- сохранять dSYM до упаковки;
- формировать manifest build → binary UUID → dSYM;
- загружать dSYM в выбранную систему только по защищённому release-процессу.

## Этап 8. Очередь и сеть

Отправитель:

- использует отдельную `URLSession`;
- отправляет только при наличии согласия;
- имеет timeout и exponential backoff;
- не блокирует запуск/выход приложения;
- не повторяет 4xx бесконечно;
- повторяет разумные 5xx/network failures;
- удаляет queue item после подтверждённого успеха;
- поддерживает `Отменить отправку`, пока item не отправлен.

Не отправлять crash payload через update-check URL или сторонние формы.

## Этап 9. Интеграция с текущей диагностикой

- `Maintenance` продолжает показывать локальную сводку.
- `DiagnosticReport` может показывать:
  - найдено собственных crash reports;
  - pending/sent/declined;
  - report IDs;
  - но не полный stack без отдельного выбора.
- SMC/input diagnostics отправлять только как отдельное attachment с preview и отдельной галочкой.

## Этап 10. Тесты

### Unit

- распознаётся crash только Kelvin;
- crash другого приложения игнорируется;
- duplicate не отправляется;
- allowlist sanitizer;
- PII golden tests;
- oversized payload truncation;
- malformed `.ips`;
- queue state machine;
- consent off/on;
- retry policy;
- schema migration.

### Integration

- тестовый локальный endpoint;
- offline → queue → online → sent;
- 400/413/429/500;
- timeout;
- backend duplicate;
- preview совпадает с отправляемым payload;
- удаление pending report;
- автоматическая отправка только после opt-in.

### Manual QA

- искусственный DEBUG crash;
- следующий запуск показывает корректную карточку;
- отказ не повторяет nag;
- согласие отправляет один раз;
- в payload нет username/path/license/input text;
- privacy settings понятны на RU/UK/EN/PT.

## Этап 11. Privacy и документация

До включения функции обновить:

- `docs/privacy.html`;
- onboarding/settings privacy copy;
- `QA.md`;
- support documentation.

Описать:

- что собирается;
- когда отправляется;
- куда;
- retention;
- как отключить;
- как удалить уже отправленный report, если backend это поддерживает;
- что сервер технически видит IP.

## Рекомендуемые коммиты

1. `docs: define crash data and consent policy`
2. `feat: add local crash report inbox`
3. `feat: sanitize crash reports with allowlist`
4. `feat: add crash preview and consent UI`
5. `feat: add reliable crash upload queue`
6. `build: archive dsyms for symbolication`
7. `test: add pii and queue regression coverage`
8. `docs: update crash reporting privacy policy`

## Definition of Done

- Kelvin обнаруживает собственный новый crash.
- Пользователь видит санитизированное содержимое до отправки.
- Default — без автоматической отправки.
- Один crash не отправляется повторно.
- Payload проходит PII-тесты.
- Есть backend rate limiting, retention и symbolication.
- В клиенте нет «секретного» API key.
- Ошибка сети не влияет на запуск приложения.
- Privacy policy соответствует реальному поведению.

