# Runbook: Обновление Kelvin с Privileged Service

## Выпуск обычной версии

### Подготовка
1. Убедитесь, что приватный EdDSA ключ сохранён в CI secrets:
   - Переменная: `SPARKLE_ED_PRIVATE_KEY`
   - Или файл: `/secure/path/sparkle_ed_key.txt`

2. Проверьте версию в `Info.plist`:
   ```bash
   /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Kelvin.app/Contents/Info.plist
   /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Kelvin.app/Contents/Info.plist
   ```

### Сборка и подпись
```bash
export DEVID_APP="Developer ID Application: Your Name (TEAMID)"
export AC_PROFILE="your-notary-profile"
export SPARKLE_ED_PRIVATE_KEY="AnrH0DpRa4DrD50GQG4dcA0a37LKeHVH7kJA6GYpsKI="

./release.sh
```

### Валидация
```bash
# Проверка подписи приложения
codesign --verify --strict --verbose=2 Kelvin.app

# Проверка нотаризации DMG
xcrun stapler validate Kelvin-*.dmg

# Валидация appcast
python3 -c "import xml.etree.ElementTree as ET; ET.parse('docs/appcast.xml'); print('✓ appcast.xml валиден')"
```

### Публикация
1. Загрузите `Kelvin-*.dmg` на хостинг
2. Загрузите `Kelvin-*.zip` (update archive) на хостинг
3. Опубликуйте `docs/appcast.xml`
4. Проверьте доступность URL из appcast

---

## Выпуск критического security update

### Экстренная процедура
1. Соберите hotfix с увеличенным build number
2. Подпишите с флагом критичности (добавьте в appcast):
   ```xml
   <sparkle:criticalUpdate>true</sparkle:criticalUpdate>
   ```
3. Опубликуйте немедленно
4. Уведомите пользователей через каналы коммуникации

### Мониторинг
- Отслеживайте процент установок через логи сервера
- Будьте готовы к rollback (см. ниже)

---

## Отзыв ошибочного релиза

### Немедленные действия
1. Удалите или переименуйте проблемный архив на сервере:
   ```bash
   mv Kelvin-1.2.0.zip Kelvin-1.2.0.zip.REVOKED
   ```

2. Обновите appcast.xml — удалите запись о проблемной версии

3. Добавьте запись о recovery-версии:
   ```xml
   <item>
     <title>Recovery Update</title>
     <sparkle:version>901</sparkle:version>
     <sparkle:shortVersionString>0.9.1</sparkle:shortVersionString>
     <enclosure url="https://trykelvin.com/Kelvin-0.9.1.zip"
                sparkle:edSignature="..." 
                length="..." 
                type="application/zip"/>
     <sparkle:criticalUpdate>true</sparkle:criticalUpdate>
   </item>
   ```

### Коммуникация
- Опубликуйте уведомление на сайте
- Ответьте на тикеты поддержки

---

## Ротация Update Signing Key

### Плановая ротация (раз в год)

#### Генерация новой пары ключей
```bash
python3 generate_sparkle_keys.py
```

#### Внедрение
1. Сохраните новый приватный ключ в CI secrets
2. Обновите `SUPublicEDKey` в `Info.plist`
3. Соберите новую версию приложения
4. Подпишите следующие релизы новым ключом

#### Период перехода (2 недели)
- Подписывайте релизы **обоими ключами** (создайте два `<item>` в appcast)
- После истечения срока отзовите старый ключ

### Потеря signing key

#### Аварийная процедура
1. Сгенерируйте новую пару ключей
2. Срочно выпустите обновление с новым публичным ключом
3. Пользователи не смогут обновиться автоматически — предложите ручную установку:
   - Скачайте DMG с сайта
   - Установите вручную в `/Applications`

---

## Временная остановка feed

### Сценарии
- Обнаружена критическая ошибка
- Сервер обновлений недоступен
- Требуется время на расследование

### Действия
1. Верните HTTP 503 на `appcast.xml`:
   ```bash
   # На сервере
   echo "Maintenance" > docs/appcast.xml
   ```

2. Или замените appcast на пустой:
   ```xml
   <?xml version="1.0"?>
   <rss><channel><title>Kelvin Updates</title></channel></rss>
   ```

3. Восстановите после решения проблемы

---

## Rollback

### Откат на предыдущую версию
1. Подготовьте архив предыдущей стабильной версии
2. Подпишите его текущим ключом
3. Добавьте в appcast с более высоким build number (если возможно)
4. Или опубликуйте как manual download

### Восстановление service
Если privileged service (`fand`) повреждён:
```bash
# Переустановка service
sudo /Applications/Kelvin.app/Contents/Resources/install-fan-helper.sh

# Проверка статуса
launchctl list | grep fand

# Логи
log show --predicate 'process == "fand"' --last 1h
```

---

## Диагностика Update Failure

### Симптомы
- Пользователь не получает обновление
- Ошибка при установке
- Service не обновляется

### Чеклист диагностики

#### 1. Проверка на стороне клиента
```bash
# Логи Sparkle
log show --predicate 'subsystem == "org.sparkle-project.Sparkle"' --last 1h

# Проверка подписи
codesign --verify --strict /Applications/Kelvin.app

# Проверка service
launchctl list | grep fand
```

#### 2. Проверка на стороне сервера
```bash
# Доступность appcast
curl -I https://trykelvin.com/appcast.xml

# Валидация XML
xmllint --noout docs/appcast.xml

# Проверка подписи архива
python3 sign_update.py Kelvin-*.zip <public-key>
```

#### 3. Типичные ошибки

| Ошибка | Причина | Решение |
|--------|---------|---------|
| `Invalid signature` | Несоответствие ключа | Проверьте SUPublicEDKey в Info.plist |
| `404 Not Found` | Архив удалён | Восстановите файл на сервере |
| `Insufficient disk space` | Мало места | Освободите ≥500 MB |
| `Service protocol mismatch` | Старый fand | Переустановите helper |

### Сбор диагностических данных
Попросите пользователя отправить:
```bash
# Экспорт логов
log show --predicate 'subsystem contains "kelvin"' --last 24h > kelvin_logs.txt

# Информация о системе
system_profiler SPSoftwareDataType SPHardwareDataType
```

---

## Проверка совместимости Privileged Service

### Handshake Protocol

При запуске приложение проверяет:
```swift
struct ServiceHandshake: Codable {
    let serviceVersion: String           // версия fand (build number)
    let protocolVersion: String          // текущая версия протокола
    let minimumCompatibleAppProtocol: String
    let timestamp: Date
}
```

### Матрица совместимости

| App Version | Service Protocol | Минимальная версия Service |
|-------------|------------------|---------------------------|
| 0.9.x       | 2.0              | 1.0                       |
| 1.0.x       | 2.0              | 2.0                       |
| 1.1.x       | 2.1              | 2.0                       |

### Алгоритм обновления

1. **Проверка совместимости**
   - Если `service.protocolVersion >= app.minimumCompatibleServiceProtocol` → OK
   - Иначе → требуется обновление service

2. **Обновление service**
   - Показать пользователю диалог с запросом пароля
   - Выполнить `install-fan-helper.sh`
   - Перезапустить daemon: `launchctl kickstart -k system/com.trykelvin.fand`

3. **Verification**
   - Повторить handshake
   - Проверить health: `launchctl list | grep fand`

---

## Контрольный список перед релизом

- [ ] EdDSA ключ сохранён в CI secrets
- [ ] Публичный ключ вставлен в `Info.plist`
- [ ] Сборка проходит без ошибок
- [ ] Тесты проходят (`./test/run-tests.sh`)
- [ ] Подпись проверена (`codesign --verify`)
- [ ] Нотаризация успешна (`xcrun stapler validate`)
- [ ] Appcast валиден (XML + подпись)
- [ ] Update archive доступен по URL
- [ ] Privileged service совместим
- [ ] Документация обновлена
- [ ] Команда поддержки уведомлена

---

## Контакты

- Разработчик: Artem Balabanov
- Сайт: https://trykelvin.com
- Поддержка: support@trykelvin.com
