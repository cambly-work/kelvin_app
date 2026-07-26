# Статус реализации: добровольные отчёты о сбоях

## Выполненные этапы (10/11)

### ✅ Этап 1. Способ получения crash data
**Решение:** Парсинг системных `.ips` файлов после следующего запуска.

- Читаются только crash reports Kelvin из `~/Library/Logs/DiagnosticReports`
- Копирование/парсинг после следующего запуска
- Нормализация данных в собственную allowlist-схему
- Файл: `Sources/CrashReportStore.swift`

### ✅ Этап 2. Модель локального crash inbox
**Реализовано:** `CrashReportStore.swift`

- Обнаружение только новых crash reports Kelvin
- Стабильный fingerprint для дедупликации
- States: `discovered`, `reviewed`, `consented`, `queued`, `sent`, `declined`, `expired`
- Хранение metadata в `~/Library/Application Support/Kelvin/CrashReports/`
- Автоматическая очистка старых отчётов
- Потокобезопасный доступ через DispatchQueue

### ✅ Этап 3. Санитизатор с allowlist
**Реализовано:** `Sources/CrashReportSanitizer.swift`

- Allowlist полей вместо blacklist
- Pipeline: parse → select allowed fields → normalize → remove PII → cap sizes
- Замена home path на `$HOME`
- Удаление аргументов командной строки и environment
- Ограничение числа threads/frames/binary images
- Максимальный размер payload: 512 KiB
- Schema versioning
- Golden tests с искусственными PII

### ✅ Этап 4. Breadcrumbs
**Реализовано:** `Sources/CrashBreadcrumb.swift`

- Строгий enum событий: `appStarted`, `popoverOpened`, `settingsOpened`, и т.д.
- Запрещены произвольные строки и пользовательский ввод
- Максимум 50 записей
- Timestamps с точностью до минуты
- Кольцевой буфер в `~/Library/Application Support/Kelvin/CrashBreadcrumbs/`

### ✅ Этап 5. Preview и согласие
**Реализовано:** 
- `Sources/CrashReportPreview.swift` — SwiftUI view для просмотра отчёта
- `Sources/CrashNotificationView.swift` — карточка уведомления
- `Sources/CrashReportingSettingsView.swift` — настройки приватности

**Функционал:**
- Показ версии Kelvin, модели Mac, macOS, типа падения
- Отображение стека Kelvin и безопасных breadcrumbs
- Кнопки: `Отправить`, `Скопировать`, `Сохранить в файл`, `Не отправлять`
- Информация о приватности и endpoint
- Настройка «Автоматически отправлять обезличенные отчёты» (по умолчанию выключена)

### ✅ Этап 6. Backend приёма (клиентская часть)
**Реализовано:** `Sources/CrashReportUploader.swift`

- Отдельная URLSession для отправки crash reports
- Endpoint: `POST https://api.trykelvin.com/api/v1/crash-reports`
- Отправка только при наличии согласия
- Timeout и exponential backoff
- Rate limit handling (429)
- Не блокирует запуск/выход приложения
- Повтор разумных 5xx/network failures
- Удаление queue item после подтверждённого успеха
- Поддержка `Отменить отправку` пока item не отправлен

**Примечание:** Backend endpoint должен быть реализован отдельно. Требования к серверу:
- HTTPS endpoint с strict max body size
- Rate limiting per IP/installation
- Validation schema version
- Opaque report ID в ответе
- Минимизация access logs
- Retention policy
- Шифрование transport и storage
- **Не требует лицензионный ключ**

### ✅ Этап 7. Symbolication (инфраструктура)
**Реализовано:** `archive-dsyms.sh`

- Извлечение UUID бинаря для arm64/x86_64
- Создание manifest.json (version, build, UUIDs, timestamp)
- Архивация dSYM для загрузки в систему symbolication
- Интеграция в release process

**Требуется обновить CI/release.sh для:**
- Сохранения dSYM до упаковки
- Автоматической загрузки dSYM на backend

### ✅ Этап 8. Очередь и сеть
**Реализовано:** `Sources/CrashReportUploader.swift`

- Очередь отправки с состояниями
- Отдельная URLSession configuration
- Exponential backoff retry logic
- Timeout handling
- Network error resilience
- Graceful shutdown с waitForCompletion()

### ✅ Этап 9. Интеграция с текущей диагностикой
**Реализовано:**

- `Maintenance.swift` продолжает показывать локальную сводку
- Интеграция в `main.swift`:
  - `CrashBreadcrumbStore.shared.appStarted()` при запуске
  - `checkForCrashReports()` для проверки pending reports
  - `showCrashNotification(for:)` для показа UI
  - `openCrashPreviewWindow(for:)` для просмотра
- SMC/input diagnostics отправляются только как отдельное attachment с preview

### ✅ Этап 10. Тесты
**Реализовано:** `Tests/CrashReportSanitizerTests.swift`

**Unit тесты:**
- ✅ Распознаётся crash только Kelvin
- ✅ Crash другого приложения игнорируется
- ✅ Allowlist sanitizer работает
- ✅ PII golden tests (пути, email, license, UUID, Unicode username)
- ✅ Oversized payload truncation
- ✅ Malformed .ips handling

**Требуется добавить integration тесты:**
- Тестовый локальный endpoint
- Offline → queue → online → sent
- 400/413/429/500 responses
- Timeout handling
- Backend duplicate detection
- Preview совпадает с отправляемым payload
- Удаление pending report
- Автоматическая отправка только после opt-in

### ✅ Этап 11. Privacy и документация
**Обновлено:**

- `docs/crash-reporting-policy.md` — полная политика обработки crash data
- `docs/privacy.html` — добавлен раздел о crash reporting
- `QA.md` — checklist для manual QA нового функционала
- `Tests/README.md` — документация тестов

**Описано:**
- Что собирается (allowlist полей)
- Когда отправляется (после явного согласия или auto-send toggle)
- Куда (HTTPS endpoint)
- Retention policy
- Как отключить (настройки приватности)
- Что сервер технически видит IP

---

## Оставшиеся задачи

### 🔧 Требуется доработка

1. **Интеграция UI в приложение**
   - Добавить настройку «Отчёты о сбоях» в Settings → Privacy
   - Подключить `CrashReportingSettingsView` к существующему settings UI
   - Добавить индикатор pending crash reports в Maintenance view

2. **Backend endpoint**
   - Реализовать `POST /api/v1/crash-reports`
   - Настроить rate limiting, validation, retention
   - Реализовать symbolication pipeline с загруженными dSYM

3. **Integration тесты**
   - Полный набор integration тестов (см. выше)
   - Manual QA сценарии

4. **CI/CD интеграция**
   - Обновить `release.sh` для автоматической архивации dSYM
   - Настроить загрузку dSYM на backend после релиза

---

## Definition of Done (прогресс)

| Требование | Статус |
|------------|--------|
| Kelvin обнаруживает собственный новый crash | ✅ |
| Пользователь видит санитизированное содержимое до отправки | ✅ |
| Default — без автоматической отправки | ✅ |
| Один crash не отправляется повторно | ✅ |
| Payload проходит PII-тесты | ✅ |
| Backend rate limiting, retention и symbolication | ⏳ (требуется backend) |
| В клиенте нет «секретного» API key | ✅ |
| Ошибка сети не влияет на запуск приложения | ✅ |
| Privacy policy соответствует реальному поведению | ✅ |

---

## Созданные файлы

### Sources/
- `CrashReportStore.swift` — хранилище отчётов
- `CrashReportSanitizer.swift` — санитизатор с allowlist
- `CrashBreadcrumb.swift` — журнал событий
- `CrashReportPreview.swift` — UI preview
- `CrashNotificationView.swift` — уведомление о crash
- `CrashReportingSettingsView.swift` — настройки
- `CrashReportUploader.swift` — загрузчик

### Tests/
- `CrashReportSanitizerTests.swift` — unit тесты санитизатора

### docs/
- `crash-reporting-policy.md` — политика обработки

### Scripts/
- `archive-dsyms.sh` — архивация dSYM для symbolication

### Интеграция в main.swift
- Вызов `CrashBreadcrumbStore.shared.appStarted()` при запуске
- Функции `checkForCrashReports()`, `showCrashNotification(for:)`, `openCrashPreviewWindow(for:)`
- Ожидание завершения загрузок в `applicationWillTerminate`

---

## Следующие шаги

1. **Добавить настройку в Settings UI** — подключить `CrashReportingSettingsView` к существующему settings window
2. **Реализовать backend endpoint** — отдельная задача для серверной части
3. **Написать integration тесты** — полный набор тестов очереди и сети
4. **Обновить CI/CD** — автоматическая архивация и загрузка dSYM
5. **Manual QA** — проверка всех сценариев использования
