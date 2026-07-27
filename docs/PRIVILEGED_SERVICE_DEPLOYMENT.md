# Руководство по внедрению Privileged Service

## Обзор

Этот документ описывает процесс внедрения единого привилегированного сервиса Kelvin для macOS 13+.

## Архитектура

```
Kelvin.app (User Space)
    ↓ XPC (Mach Services)
KelvinPrivilegedHelper (Root, Launch Daemon)
    ├── FanControllerService
    ├── ChargeControllerService  
    ├── PowerMetricsService
    ├── FirewallService
    ├── HostBlockService
    └── GPUModeService
```

## Требования к сборке

### 1. Entitlements

Добавьте в entitlements файла приложения:

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>TEAM_ID.com.trykelvin.kelvin</string>
</array>

<key>com.apple.service-management.enabled</key>
<true/>
```

### 2. Структура Bundle

Привилегированный хелпер должен находиться по пути:
```
Kelvin.app/Contents/Library/LaunchDaemons/com.trykelvin.kelvin.privilegedHelper
```

### 3. Code Signing

- Приложение и хелпер должны быть подписаны одним Team ID
- Хелпер должен иметь entitlement `com.apple.security.privileged`
- Используйте hardened runtime для обоих компонентов

## Процесс установки

### Шаг 1: Проверка состояния

```swift
let installer = PrivilegedServiceInstaller()

switch installer.status {
case .enabled:
    // Сервис готов к работе
case .notFound:
    // Требуется установка
case .requiresApproval:
    // Требуется одобрение в System Settings
case .invalid:
    // Ошибка конфигурации
}
```

### Шаг 2: Регистрация

```swift
do {
    try installer.register()
} catch .approvalRequired {
    // Показать UI с инструкцией открыть System Settings
    installer.openSystemSettingsForApproval()
} catch {
    // Обработать ошибку
}
```

### Шаг 3: Миграция (если требуется)

```swift
let migrator = LegacyDaemonMigrator()

if migrator.migrationRequired {
    do {
        try migrator.migrate()
    } catch {
        // Обработать ошибку миграции
    }
}
```

## Диагностика

Сбор отчета о состоянии:

```swift
let diagnostics = PrivilegedServiceDiagnostics()
diagnostics.printReport()

// Или получить структурированный отчет
let report = diagnostics.collectReport()
```

## Безопасность

### Валидация клиента

Привилегированный сервис проверяет:
- Code signature клиента
- Bundle ID
- Team ID
- Protocol version

### Lease Management

Для операций fan/charge используется система аренды:
- App получает lease ID при начале управления
- При потере связи или истечении lease сервис возвращается в безопасное состояние
- Watchdog автоматически сбрасывает настройки при crash app

### Безопасные значения по умолчанию

- Fans: Automatic (системное управление)
- Charge Limit: 80% (или системный дефолт)
- Firewall: Без изменений существующих правил пользователя

## Обновление сервиса

При обновлении приложения:
1. Проверить protocol compatibility
2. Если совместим - сохранить текущую конфигурацию
3. Если не совместим - выполнить rollback к safe state перед обновлением

## Удаление

```swift
// 1. Сбросить настройки к безопасным
// 2. Вызвать uninstall
try installer.unregister()

// 3. Опционально: удалить файлы поддержки
```

## Поддерживаемые macOS

- **macOS 13+**: Полный функционал через ServiceManagement API
- **macOS 11-12**: Требуется fallback на SMJobBless или legacy installer (не реализовано в текущей версии)

## Troubleshooting

### Сервис не устанавливается

1. Проверить консоль на ошибки code signing
2. Убедиться, что приложение в /Applications
3. Проверить entitlements файла

### Требуется повторное одобрение

Происходит при:
- Изменении Team ID
- Изменении bundle identifier
- Повреждении подписи

Решение: переустановить приложение из доверенного источника.

### Конфликт со старыми демонами

Использовать `LegacyDaemonMigrator` для автоматической очистки.

## Тестирование

### Unit Tests

- Валидация всех типов запросов
- Проверка boundary conditions (RPM, temperature, charge %)
- Тесты migration state machine

### Integration Tests

- Fresh install на чистой системе
- Update со старой версии
- Cancel во время approval flow
- Uninstall и reinstall

### Hardware Tests

- M1/M2 Mac без вентиляторов (fanless)
- Intel Mac с dual GPU
- Mac без батареи

## Чеклист релиза

- [ ] Пройдены security tests
- [ ] Протестировано на 3+ версиях macOS
- [ ] Протестировано на 3+ типах hardware
- [ ] Документация обновлена
- [ ] Migration протестирована на старых установках
- [ ] Uninstall оставляет систему в чистом состоянии
