# Инвентаризация привилегированных операций Kelvin

## Обзор

Этот документ описывает все привилегированные операции в Kelvin, их текущую реализацию, риски и план миграции на единый Privileged Service.

## Таблица операций

| Операция | Текущая реализация | Нужен root | Уровень риска | Новый API | Приоритет |
|----------|-------------------|------------|---------------|-----------|-----------|
| **Fan Profile** | `fand` daemon + JSON config | Да | Высокий | `setFanProfile(_:)` | 1 |
| **Charge Limit** | `fand` config (BCLM) | Да | Высокий | `setChargeLimit(_:)` | 1 |
| **Power Metrics** | `powerd` shell script | Да | Средний | `readPowerMetrics(_:)` | 2 |
| **GPU Switching** | `osascript pmset gpuswitch` | Да | Средний | `setGPUMode(_:)` | 2 |
| **Firewall** | admin shell (`socketfilterfw`) | Да | Высокий | `setFirewallEnabled(_:)`, `setFirewallRule(_:)` | 3 |
| **Hosts Blocklist** | root script (`/etc/hosts`) | Да | Высокий | `applyHostBlocklist(_:)` | 3 |
| **Gatekeeper Toggle** | admin shell (`spctl`) | Да | Очень высокий | **Не включать** | - |
| **Clear Quarantine** | admin shell (`xattr`) | Условно | Высокий | **Не включать** | - |

## Детальный анализ

### 1. Fan Profile (Вентиляторы)

**Текущее состояние:**
- Файл: `Sources/FanController.swift`
- Демон: `helper/fand.swift` → `com.trykelvin.kelvin.fand`
- Конфигурация: `~/Library/Application Support/Kelvin/fan-profile.json`
- Установка: `helper/install-fan-helper.sh`

**Риски:**
- Прямой доступ к SMC (System Management Controller)
- Неправильные настройки могут вызвать перегрев
- Требует постоянного контроля температуры

**Требования к новому API:**
```swift
setFanProfile(_ profile: ValidatedFanProfile)
restoreFansAutomatic()
```

**Валидация:**
- Диапазон RPM: 0-10000
- Критическая температура: 50-120°C
- Lease/watchdog для возврата в auto при сбое приложения

**Миграция:**
- Обнаружить старый `com.trykelvin.kelvin.fand`
- Остановить старый демон
- Сохранить пользовательские профили
- Применить безопасный режим (auto)
- Удалить старый plist

---

### 2. Charge Limit (Ограничение заряда)

**Текущее состояние:**
- Файл: `Sources/ChargeControl.swift`
- Демон: через `fand` (BCLM - Battery Charge Limit Module)
- Конфигурация: `~/Library/Application Support/Kelvin/charge-limit.json`
- Установка: через `HelperInstall.fandInstalled`

**Риски:**
- Вмешательство в работу батареи
- Неправильные настройки могут сократить срок службы батареи
- Требует точного контроля состояния заряда

**Требования к новому API:**
```swift
setChargeLimit(_ percent: Int) // 50-100%
```

**Валидация:**
- Диапазон: 50-100%
- Безопасный минимум по умолчанию: 80%
- rollback при lease expiry

**Миграция:**
- Объединить с fan migration
- Сохранить текущие настройки sail/limit режимов

---

### 3. Power Metrics (Метрики питания)

**Текущее состояние:**
- Вызов `/usr/bin/powermetrics` через shell
- Парсинг output в `Sources/PowerInfo.swift`

**Риски:**
- Средний риск (только чтение)
- Возможность injection через аргументы
- Неограниченный вывод

**Требования к новому API:**
```swift
readPowerMetrics(_ options: PowerMetricsOptions) -> PowerMetricsResult
```

**Безопасность:**
- Фиксированный путь: `/usr/bin/powermetrics`
- Allowlist аргументов
- Контролируемый timeout
- Bounded output

---

### 4. GPU Switching (Переключение графики)

**Текущее состояние:**
- Файл: `Sources/GPUInfo.swift`
- Механизм: `osascript` → `pmset gpuswitch`
- Требует root для каждого переключения

**Риски:**
- Средний риск
- Требует перезагрузки/логинаута на некоторых моделях
- Только Intel dual-GPU Mac

**Требования к новому API:**
```swift
setGPUMode(_ mode: GPUMode) -> Bool
```

**Валидация:**
- Проверка поддержки hardware (Intel, 2+ GPU)
- Mode enum: `.integrated`, `.discrete`, `.automatic`
- Проверка фактического режима после применения

**Миграция:**
- Больше не использовать `osascript`
- Прямой вызов `/usr/bin/pmset` из сервиса

---

### 5. Firewall (Брандмауэр)

**Текущее состояние:**
- Файл: `Sources/Firewall.swift`
- Binary: `/usr/libexec/ApplicationFirewall/socketfilterfw`
- Установка правил через `admin shell`

**Риски:**
- Высокий риск (сетевая безопасность)
- Shell injection через пути приложений
- Возможность ослабить защиту системы

**Требования к новому API:**
```swift
setFirewallEnabled(_ enabled: Bool)
setFirewallRule(_ rule: ValidatedFirewallRule)
```

**Валидация:**
- Абсолютный путь к `.app`
- Проверка существования
- Каноникализация пути
- Нет shell metacharacters

**Политика:**
- Не удалять пользовательские правила
- Только Kelvin-managed правила

---

### 6. Hosts Blocklist (Блокировка доменов)

**Текущее состояние:**
- Файл: `Sources/HostBlock.swift`
- Скрипт: `helper/apply-blocklist.sh`
- Файл: `/etc/hosts`

**Риски:**
- Высокий риск (системный файл)
- Повреждение `/etc/hosts` ломает DNS
- Shell injection через домены

**Требования к новому API:**
```swift
applyHostBlocklist(_ domains: [ValidatedDomain])
```

**Валидация:**
- Строгая DNS-name валидация (RFC 1035)
- Лимит числа доменов: 1000
- Лимит длины: 253 символа
- Атомарная запись только Kelvin секции

**Формат:**
```
# >>> Kelvin blocklist >>>
0.0.0.0 example.com
0.0.0.0 tracker.example.org
# <<< Kelvin blocklist <<<
```

---

## Исключённые операции

### Gatekeeper Toggle ⚠️

**Решение:** НЕ включать в постоянный сервис

**Причины:**
- Очень высокий риск безопасности
- Автоматическое ослабление системной защиты
- Требует явного подтверждения на каждое действие

**Альтернатива:**
- Оставить как разовую операцию с отдельным prompt
- Требовать дополнительное подтверждение каждый раз

---

### Clear Quarantine ⚠️

**Решение:** НЕ включать в постоянный сервис

**Причины:**
- Обход системы безопасности macOS
- Риск выполнения непроверенного кода
- Обычно не требует root (файл пользователя)

**Альтернатива:**
- Пытаться без root сначала
- Если не выходит — отдельный admin prompt

---

## План миграции

### Этап 1: Skeleton + Handshake ✅
- [x] `PrivilegedProtocol.swift` — версионированный протокол
- [x] `PrivilegedServiceManager.swift` — координатор установки
- [ ] Privileged Service executable
- [ ] XPC interface

### Этап 2: Power Metrics + GPU
- [ ] `readPowerMetrics` за сервисом
- [ ] `setGPUMode` за сервисом
- [ ] Удалить `osascript` вызовы

### Этап 3: Fan/Charge (требует QA)
- [ ] Миграция старых демонов
- [ ] Watchdog/lease механизм
- [ ] Safe rollback

### Этап 4: Firewall + Hosts
- [ ] Typed firewall API
- [ ] Validated domain API
- [ ] Атомарные изменения

### Этап 5: Завершение
- [ ] Удаление legacy paths
- [ ] Обновление uninstall scripts
- [ ] Документация для пользователей

---

## Требования к безопасности

### Client Validation
Сервис ОБЯЗАН проверять:
- ✅ Audit token клиента
- ✅ Code signature
- ✅ Bundle identifier
- ✅ Team ID / designated requirement
- ✅ Protocol version

### Request Validation
- ❌ Никаких произвольных команд
- ❌ Никаких shell scripts от клиента
- ✅ Только типизированные enum запросы
- ✅ Валидация всех параметров
- ✅ Bounded payloads

### Error Handling
- Machine-readable error codes
- Human-readable descriptions
- Safe defaults on failure
- Audit logging (без sensitive data)

---

## Supported Hardware

### Must Test On:
- [ ] M1/M2 Air (fanless)
- [ ] Apple Silicon Mac с вентиляторами
- [ ] Intel single-GPU
- [ ] Intel dual-GPU (gpuswitch)
- [ ] Mac без батареи (desktop)

### Feature Availability:
| Feature | Apple Silicon | Intel | Notes |
|---------|--------------|-------|-------|
| Fan Control | ✅ (если есть fans) | ✅ | Fanless → unsupported |
| Charge Limit | ✅ | ✅ | Требуется батарея |
| GPU Switch | ❌ | ✅ (dual only) | Apple Silicon — один GPU |
| Power Metrics | ✅ | ✅ | Universal |

---

## Definition of Done

- [ ] После однократной установки — нет повторных паролей
- [ ] GPU switching без `osascript` на каждый выбор
- [ ] Нет универсального root shell API
- [ ] Root service проверяет подпись клиента
- [ ] Version handshake между app и service
- [ ] Fan/charge имеют watchdog и rollback
- [ ] Installation/repair/uninstall из UI
- [ ] Старые демоны мигрированы идемпотентно
- [ ] Диагностика понятна пользователю
- [ ] Решение для macOS 11-12 задокументировано
- [ ] Security tests пройдены
- [ ] Hardware QA завершено
