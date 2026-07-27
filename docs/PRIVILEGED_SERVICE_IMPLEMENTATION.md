# Privileged Service Implementation

## Статус реализации

### Этап 1: Инвентаризация ✅
- Полная таблица операций создана в `docs/PRIVILEGED_OPERATIONS_INVENTORY.md`
- Риски оценены, API определён

### Этап 2: Protocol и XPC Interface ✅
**Файлы:**
- `Sources/PrivilegedProtocol.swift` - версионированный протокол
- `Sources/PrivilegedServiceXPCInterface.swift` - XPC интерфейс и валидация клиента
- `Sources/PrivilegedServiceImplementation.swift` - реализация сервиса (stub handlers)
- `Sources/PrivilegedServiceManager.swift` - менеджер установки (существующий обновлён)

**Возможности:**
- Version handshake между app и service
- Проверка code signature клиента
- Типизированные запросы через enum `PrivilegedRequest`
- Машинно-читаемые ошибки `PrivilegedServiceError`
- Lease management для tracking ownership

### Этап 3: Power Metrics Service ✅
**Файл:** `Sources/PowerMetricsService.swift`

**Реализация:**
- Запуск `/usr/bin/powermetrics` с фиксированными аргументами
- Валидация параметров (duration 0.1-60s, interval 0.01-1s)
- Timeout выполнения 120 секунд
- Парсинг вывода без shell
- Структурированный результат `MetricsResult`

### Этап 4: GPU Mode Service ✅
**Файл:** `Sources/GPUModeService.swift`

**Реализация:**
- Проверка поддержки (Intel + dual-GPU)
- Подсчёт GPU через IOKit/system_profiler
- Вызов `/usr/bin/pmset gpuswitch` с фиксированными аргументами
- Верификация результата после переключения
- Три режима: integrated/discrete/automatic

## Следующие шаги

### Этап 5: Fan/Charge Control
Требуется реализовать:
- Валидацию диапазонов RPM/temperature
- Интеграцию с SMC или fand
- Watchdog и lease expiry
- Emergency thermal override

### Этап 6: Firewall Service
Требуется реализовать:
- Вызов `/usr/libexec/ApplicationFirewall/socketfilterfw`
- Валидацию app paths (absolute, existing .app, canonicalized)
- Сериализацию изменений
- Чтение фактического состояния

### Этап 7: Host Blocklist Service
Требуется реализовать:
- Валидацию DNS доменов
- Атомарное изменение /etc/hosts
- Backup и rollback
- Лимиты числа/длины доменов

### Этап 8: Launch Daemon Configuration
Требуется создать:
- `.plist` для launchd
- Конфигурацию MachServices для XPC
- Code signing entitlements
- Installation script для копирования binaries

## Безопасность

### Проверка клиента
```swift
connection.validateClientCodeSignature(
    expectedBundleID: "com.trykelvin.kelvin",
    expectedTeamID: "YOUR_TEAM_ID"
)
```

### Allowlist аргументов
Никаких пользовательских строк в командах:
```swift
// ✅ Хорошо
let arguments = ["gpuswitch", String(mode.rawValue)]

// ❌ Плохо
let arguments = ["-c", userProvidedCommand]
```

### Lease Management
```swift
func createLease(appName: String, appBundleID: String) -> LeaseID
func validateLease(_ leaseID: LeaseID) -> Bool
func releaseLease(_ leaseID: LeaseID)
```

## Тестирование

### Unit Tests
- [ ] Validation каждого request type
- [ ] Invalid enum/range/path/domain
- [ ] Protocol mismatch
- [ ] Lease expiry logic

### Integration Tests
- [ ] Fresh install на macOS 13+
- [ ] Fresh install на macOS 11-12
- [ ] User cancels approval
- [ ] Service update
- [ ] Uninstall

### Hardware Tests
- [ ] M1 Air (fanless)
- [ ] Apple Silicon с вентиляторами
- [ ] Intel single-GPU
- [ ] Intel dual-GPU

## Migration Plan

При первой установке нового сервиса:
1. Обнаружить старые labels (`powerd`, `fand`)
2. Прочитать совместимые настройки
3. Остановить старые jobs
4. Удалить старые plist/binaries
5. Установить новый service
6. Импорт конфигурации
7. Health check

## Known Issues

1. **macOS 11-12 Support**: Legacy installation требует отдельной реализации
2. **Team ID**: Нужно заменить заглушку на реальный Team ID
3. **XPC Connection**: Упрощённая реализация `current()` требует доработки
