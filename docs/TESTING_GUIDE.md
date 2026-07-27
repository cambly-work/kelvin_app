# Руководство по тестированию Privileged Service

## Аппаратные конфигурации для тестирования

### 1. Apple Silicon (M1/M2/M3)

#### M1 MacBook Air (fanless)
- **Ожидание:** `fanControl` capability недоступна
- **Проверка:** UI показывает "unsupported" вместо ошибки установки
- **Тест:** Установка сервиса должна пройти успешно, но без управления вентиляторами

#### M1/M2 MacBook Pro (с вентиляторами)
- **Ожидание:** Полная поддержка `fanControl` и `chargeLimit`
- **Проверка:** 
  - Профили вентиляторов применяются корректно
  - Lease watchdog работает (сброс при закрытии app)
  - Emergency thermal override приоритетнее пользовательского профиля

#### Mac mini / Mac Studio
- **Ожидание:** Поддержка `fanControl`, отсутствие `chargeLimit` (нет батареи)
- **Проверка:** Graceful degradation для отсутствующих capabilities

### 2. Intel Mac

#### Intel dual-GPU (например, MacBook Pro 2015-2019)
- **Ожидание:** Поддержка `gpuMode` switching
- **Проверка:**
  - `pmset gpuswitch` работает без AppleScript prompt
  - Фактический режим верифицируется после переключения
  - UI показывает совместимость до попытки переключения

#### Intel single-GPU
- **Ожидание:** `gpuMode` capability недоступна
- **Проверка:** UI скрывает или дизейблит опции GPU switching

## Сценарии тестирования

### Fresh Install

1. **Чистая установка**
   ```
   - Запустить Kelvin впервые
   - Открыть настройки → раздел "Системные функции"
   - Нажать "Установить"
   - Пройти системный prompt
   - Проверить статус "healthy"
   - Убедиться, что capabilities отображаются
   ```

2. **Отмена установки пользователем**
   ```
   - Нажать "Установить"
   - Отменить в системном prompt
   - Проверить возврат toggle в исходное состояние
   - Убедиться в отсутствии пугающих алертов
   ```

3. **Требуется approval в System Settings**
   ```
   - Нажать "Установить"
   - Получить статус "approvalRequired"
   - Нажать "Открыть настройки системы"
   - Разрешить в Security & Privacy
   - Вернуться в Kelvin, проверить "healthy"
   ```

### Migration со старых демонов

4. **Миграция с fand/powerd**
   ```
   - Установить старую версию Kelvin с fand
   - Настроить профиль вентиляторов
   - Обновиться на новую версию с unified service
   - Проверить:
     * Старые jobs остановлены
     * Конфигурация импортирована
     * Fans не остались в manual режиме
     * Migration marker записан
   ```

5. **Идемпотентность миграции**
   ```
   - Запустить миграцию повторно
   - Убедиться, что ничего не ломается
   - Проверить отсутствие дубликатов jobs
   ```

### Operations Testing

6. **Fan Control с lease**
   ```
   - Установить fan profile
   - Закрыть Kelvin принудительно (kill)
   - Подождать expiry lease (5 мин)
   - Проверить сброс fans в auto
   - Проверить логи watchdog
   ```

7. **Charge Limit rollback**
   ```
   - Установить лимит заряда 80%
   - Закрыть Kelvin
   - Дождаться lease expiry
   - Проверить возврат к безопасной политике
   ```

8. **GPU Switching verification**
   ```
   - Переключить GPU mode
   - Перечитать фактический режим
   - Убедиться в совпадении с запрошенным
   - Проверить отсутствие password prompt
   ```

9. **Firewall rules**
   ```
   - Добавить правило для.app
   - Проверить валидацию пути
   - Перечитать фактическое состояние
   - Удалить правило
   - Проверить очистку
   ```

10. **Host Blocklist**
    ```
    - Применить список доменов
    - Проверить валидацию DNS names
    - Проверить атомарность изменения /etc/hosts
    - Убедиться в наличии backup
    - Откатить изменения
    - Проверить восстановление из backup
    ```

### Security Tests

11. **Client Validation**
    ```
    - Попытаться подключиться к сервису из неподписанного процесса
    - Ожидание: отказ с ошибкой "unauthorizedClient"
    
    - Изменить bundle ID тестового клиента
    - Ожидание: отказ
    
    - Использовать другой Team ID
    - Ожидание: отказ
    ```

12. **Request Validation**
    ```
    - Отправить invalid enum value
    - Ожидание: "validationFailed"
    
    - Отправить RPM вне диапазона (negative, >10000)
    - Ожидание: "validationFailed"
    
    - Отправить путь с shell injection символами
    - Ожидание: "validationFailed"
    
    - Отправить malformed JSON payload
    - Ожидание: graceful отказ без crash
    ```

13. **Concurrent Requests**
    ```
    - Одновременно отправить conflicting fan profiles
    - Ожидание: сериализация или последний wins
    - Проверить отсутствие race conditions
    ```

### Update Scenarios

14. **Update Service**
    ```
    - Установить сервис v1.0
    - Обновить приложение на версию с service v1.1
    - Проверить detection "updateRequired"
    - Нажать "Обновить"
    - Проверить успешную установку новой версии
    - Проверить protocol compatibility
    ```

15. **Incompatible Protocol**
    ```
    - Установить сервис с protocol v1
    - Запустить app с protocol v2 (breaking changes)
    - Ожидание: статус "incompatible"
    - Предложить переустановку
    ```

### Uninstall Testing

16. **Полное удаление**
    ```
    - Нажать "Удалить" в настройках
    - Подтвердить
    - Проверить:
      * Fans → auto
      * Charge limit снят
      * Firewall rules Kelvin удалены
      * Hosts blocklist отключён
      * Service unregister
      * Root files удалены
      * Jobs/processes отсутствуют
    ```

17. **Uninstall при неработающем сервисе**
    ```
    - Kill сервис вручную
    - Попробовать удалить через UI
    - Ожидание: graceful cleanup или инструкция
    ```

### Edge Cases

18. **App в Downloads**
    ```
    - Запустить Kelvin из ~/Downloads
    - Попробовать установить сервис
    - Ожидание: предложение переместить в /Applications
    ```

19. **Reboot**
    ```
    - Установить сервис
    - Перезагрузить Mac
    - Проверить автозапуск сервиса
    - Проверить сохранение конфигурации
    ```

20. **Multiple macOS Versions**
    ```
    - Протестировать на:
      * macOS 11 (Big Sur) - legacy fallback?
      * macOS 12 (Monterey)
      * macOS 13+ (Ventura+) - ServiceManagement
    - Проверить consistent behavior
    ```

## Checklist для каждого теста

- [ ] Тест воспроизводим
- [ ] Ожидаемый результат задокументирован
- [ ] Фактический результат записан
- [ ] Логи собраны (console.app, unified logging)
- [ ] Скриншоты UI состояний сделаны
- [ ] Найденные баги заведены в issue tracker
- [ ] Recovery procedure проверена при failure

## Инструменты диагностики

```bash
# Проверка статуса launchd
launchctl list | grep kelvin

# Просмотр логов сервиса
log show --predicate 'subsystem == "com.trykelvin.kelvin"' --last 1h

# Проверка code signature
codesign -dv --verbose=4 /Library/PrivilegedHelperTools/com.trykelvin.kelvin.service

# Проверка XPC endpoints
plutil -p /Library/LaunchDaemons/com.trykelvin.kelvin.service.plist

# Диагностика состояния
# (кнопка "Диагностика" в UI должна выводить структурированный отчёт)
```

## Критерии Acceptance

- [ ] После однократной установки операции не требуют пароля
- [ ] GPU switching работает без AppleScript
- [ ] Нет универсального root shell API
- [ ] Client validation работает (неподписанный клиент отвергается)
- [ ] Version handshake предотвращает incompatibility issues
- [ ] Fan/charge watchdog и rollback работают
- [ ] Установка/repair/update/uninstall доступны из UI
- [ ] Старые демоны мигрируются идемпотентно
- [ ] Диагностика понятна пользователю
- [ ] Все hardware конфигурации протестированы
