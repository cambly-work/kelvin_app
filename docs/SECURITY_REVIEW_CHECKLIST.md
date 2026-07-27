# Security Review Checklist для Privileged Service

## 1. Code Signing & Entitlements

### App Entitlements
- [ ] `Kelvin.entitlements` содержит минимально необходимые права
- [ ] `com.apple.security.application-groups` настроен с правильным Team ID
- [ ] `com.apple.security.inherit` установлен для XPC communication
- [ ] Временные exception entitlements задокументированы
- [ ] `com.apple.security.get-task-allow` удалён перед релизом в App Store

### Service Entitlements
- [ ] `KelvinPrivilegedService.entitlements` содержит только required privileges
- [ ] Root доступ явно разрешён и обоснован
- [ ] Hardened Runtime включён
- [ ] Library Validation не отключена без необходимости

### Code Signature Verification
```bash
# Проверка app
codesign -dv --verbose=4 Kelvin.app

# Проверка сервиса после установки
codesign -dv --verbose=4 /Library/PrivilegedHelperTools/com.trykelvin.kelvin.service

# Проверка requirements
codesign -r - /Library/PrivilegedHelperTools/com.trykelvin.kelvin.service
```

## 2. XPC Security

### Client Validation
- [ ] Audit token проверяется для каждого подключения
- [ ] Code signature валидируется с designated requirement
- [ ] Bundle ID проверяется на exact match
- [ ] Team ID проверяется на совпадение
- [ ] Protocol version handshake реализован

### Request Validation
- [ ] Все входящие данные валидируются перед использованием
- [ ] Enum values проверяются на допустимые значения
- [ ] Числовые параметры в диапазонах (RPM, temp, charge limit)
- [ ] Пути к файлам canonicalized и проверены
- [ ] DNS names валидируются по RFC 1035
- [ ] Нет shell injection через конкатенацию аргументов

### Response Handling
- [ ] Ошибки не содержат sensitive information
- [ ] Error codes machine-readable для app
- [ ] Human-readable description безопасен

## 3. Privileged Operations Safety

### Fan Control
- [ ] RPM limits validated (0-10000)
- [ ] Temperature thresholds в безопасном диапазоне (50-120°C)
- [ ] Emergency thermal override имеет приоритет
- [ ] Lease expiry возвращает fans в auto
- [ ] Unsupported devices получают graceful degradation

### Charge Limit
- [ ] Процент заряда в диапазоне (0-100)
- [ ] Safe default policy при lease expiry
- [ ] Battery presence check перед применением

### GPU Switching
- [ ] Только Intel dual-GPU Mac поддерживаются
- [ ] Mode enum ограничен (0/1/2)
- [ ] Фактический режим верифицируется после изменения
- [ ] Нет AppleScript password prompt

### Firewall
- [ ] Только socketfilterfw используется (fixed path)
- [ ] App paths validated: absolute, existing .app, canonicalized
- [ ] No shell metacharacters в путях
- [ ] Changes serialized
- [ ] State re-read после операции

### Host Blocklist
- [ ] Домены валидируются как DNS names
- [ ] Лимиты на количество и длину доменов
- [ ] Атомарное изменение /etc/hosts
- [ ] Backup создаётся перед изменением
- [ ] Rollback работает корректно
- [ ] Только Kelvin-managed section модифицируется

### Опасные операции (не включены в сервис)
- [ ] Gatekeeper disable не доступен через постоянный сервис
- [ ] Массовое снятие quarantine не автоматизировано
- [ ] Любое ослабление системной защиты требует отдельного явного подтверждения

## 4. Installation Security

### Pre-flight Checks
- [ ] App location проверен (/Applications рекомендуется)
- [ ] Code signature app валидирована
- [ ] Team ID совпадает с entitlements

### Installation Process
- [ ] SMJobBless или ServiceManagement API используется правильно
- [ ] Binary копируется в /Library/PrivilegedHelperTools/
- [ ] Plist устанавливается в /Library/LaunchDaemons/
- [ ] Permissions установлены корректно (root:wheel, 0544)

### Migration
- [ ] Старые демоны обнаруживаются по label
- [ ] Конфигурация читается перед остановкой
- [ ] Старые jobs останавливаются перед установкой нового
- [ ] Fans переводятся в safe state во время миграции
- [ ] Migration marker записывается
- [ ] Процесс идемпотентен

## 5. Logging & Diagnostics

### Unified Logging
- [ ] Subsystem: `com.trykelvin.kelvin`
- [ ] Categories разделены по компонентам
- [ ] Нет пользовательских данных в логах
- [ ] Нет путей к файлам в public fields
- [ ] Bounded diagnostics (no unlimited logging)

### Diagnostic Report
- [ ] Installation state включён
- [ ] Service version и protocol version
- [ ] Supported capabilities listed
- [ ] Last health check timestamp
- [ ] Last error code (safe)
- [ ] Launchd state
- [ ] Нет root secrets
- [ ] Нет raw log dumps

## 6. Threat Modeling

### Attack Vectors Considered
- [ ] Неподписанный клиент пытается подключиться
- [ ] Клиент с другим Team ID
- [ ] Spoofed bundle ID
- [ ] Malformed XPC payload
- [ ] Oversized payload (DoS)
- [ ] Replay attacks
- [ ] Concurrent conflicting requests
- [ ] Service crash mid-operation
- [ ] Race conditions в file operations
- [ ] Symlink attacks на пути к файлам
- [ ] Time-of-check to time-of-use (TOCTOU)

### Mitigations Implemented
- [ ] Code signature validation
- [ ] Request/response validation
- [ ] Size limits на payloads
- [ ] Serial execution или locking
- [ ] Atomic file operations
- [ ] Symlink resolution перед использованием путей
- [ ] Lease mechanism для ownership tracking

## 7. Update Security

### Update Process
- [ ] Только подписанное app может обновить сервис
- [ ] Team ID проверяется при обновлении
- [ ] Bundle ID проверяется
- [ ] Protocol compatibility checked
- [ ] Staged replacement (new version validated before replacing)
- [ ] Health check новой версии перед завершением

### Rollback
- [ ] Предыдущая версия сохраняется временно
- [ ] Rollback при failed health check
- [ ] Cleanup old versions после успешного update

## 8. Uninstall Security

### Uninstall Process
- [ ] Fans возвращаются в auto
- [ ] Charge policy нормализуется
- [ ] Только Kelvin firewall rules удаляются
- [ ] Hosts blocklist отключается с rollback
- [ ] Service unregister из launchd
- [ ] Root files удаляются
- [ ] Verification отсутствия jobs/processes
- [ ] Clear result reported

### Orphaned Service Handling
- [ ] uninstall-app.sh вызывает официальный uninstaller
- [ ] Или объясняет один системный шаг для orphaned service
- [ ] Не требует ручного набора нескольких команд

## 9. Compliance

### Notarization
- [ ] Hardened Runtime включён
- [ ] Entitlements минимальны и обоснованы
- [ ] Нет отключенных security features без необходимости
- [ ] notarization проходит успешно

### Privacy
- [ ] Нет сбора персональных данных
- [ ] Логи не содержат user-identifiable information
- [ ] Diagnostic report не экспортирует sensitive data

## 10. Documentation

### User-Facing
- [ ] Объяснение зачем нужен сервис
- [ ] Список возможностей которые он получает
- [ ] Инструкция как удалить
- [ ] Troubleshooting guide

### Developer
- [ ] Architecture diagram
- [ ] API documentation
- [ ] Security model explained
- [ ] Threat model documented
- [ ] Test plan

## Sign-off

- [ ] Code review completed
- [ ] Security review completed
- [ ] All tests passed
- [ ] Documentation complete
- [ ] Ready for release

---

**Reviewer:** _________________  
**Date:** _________________  
**Notes:** _________________
