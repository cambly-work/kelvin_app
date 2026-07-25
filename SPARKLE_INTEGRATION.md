# Интеграция Sparkle 2.9.4 в Kelvin

## Обзор

Интегрирован Sparkle 2.9.4 для безопасных автоматических обновлений с EdDSA-подписью артефактов.

## Изменения в проекте

### 1. Build system (`build.sh`)
- Добавлено копирование `Sparkle.framework` в `Kelvin.app/Contents/Frameworks/`
- Фреймворк подписывается ad-hoc при локальной сборке

### 2. Info.plist
Добавлены ключи конфигурации Sparkle:
- `SUFeedURL` — URL appcast.xml
- `SUPublicEDKey` — публичный EdDSA ключ (требует замены после генерации)
- `SUEnableAutomaticChecks` — автопроверка обновлений
- `SUVerifyUpdateBeforeExtraction` — проверка подписи перед распаковкой

### 3. Updater.swift
- Создан протокол `UpdateProviding` для абстракции
- Реализован `SparkleUpdater` — адаптер для Sparkle 2.x
- Legacy `Updater` делегирует вызовы Sparkle с миграцией настроек

### 4. Release pipeline (`release.sh`)
- Генерация XML appcast вместо JSON
- Создание update archive (ZIP)
- Подпись архива через `bin/sign_update` с EdDSA ключом
- Переменные окружения: `SPARKLE_ED_KEY_FILE` или `SPARKLE_ED_PRIVATE_KEY`

## Настройка для релиза

### Шаг 1: Генерация ключей

```bash
./generate_update_keys.sh
```

Выведет пару ключей:
- **Приватный ключ** — сохранить в CI secrets / keychain релизной машины
- **Публичный ключ** — вставить в `Info.plist` вместо `<!-- INSERT_PUBLIC_ED_KEY_HERE -->`

### Шаг 2: Обновление Info.plist

Заменить заглушку на реальный публичный ключ:

```xml
<key>SUPublicEDKey</key>
<string>实际的_публичный_ключ_здесь</string>
```

### Шаг 3: Настройка CI

Для подписи релизных обновлений установить переменные:

```bash
export SPARKLE_ED_KEY_FILE=/path/to/private_ed_key
# ИЛИ
export SPARKLE_ED_PRIVATE_KEY="-----BEGIN ED PRIVATE KEY-----..."
```

### Шаг 4: Публикация appcast

После `./release.sh`:
- `docs/appcast.xml` — feed для Sparkle
- `Kelvin-X.Y.Z.zip` — update archive с подписью
- Загрузить оба файла на хостинг (`https://trykelvin.com/`)

## Безопасность

### Требования
1. **Приватный ключ никогда не попадает в репозиторий**
   - Добавлен в `.gitignore`
   - Хранится только в CI secrets / keychain
   
2. **Подпись проверяется перед установкой**
   - `SUVerifyUpdateBeforeExtraction = true`
   - Неподписанный архив не установится

3. **HTTPS + EdDSA**
   - Двойная защита: транспортная + криптографическая

### Ротация ключей

При компрометации приватного ключа:
1. Сгенерировать новую пару
2. Обновить `SUPublicEDKey` в Info.plist
3. Подписать новые релизы новым ключом
4. Старые релизы останутся валидными (подписаны старым ключом)

## Тестирование

### Локальная сборка
```bash
./build.sh
# Запустить Kelvin.app — Sparkle проверит обновления при запуске
```

### Релизная сборка (симуляция)
```bash
export SPARKLE_ED_KEY_FILE=./update_keys.txt
./release.sh
# Проверить docs/appcast.xml на наличие edSignature
```

## Известные ограничения

- macOS 11.0+ поддерживается (Sparkle требует 10.13+)
- Universal Binary уже внутри Sparkle.framework
- При первой установке может потребоваться разрешение на доступ к файлам

## Ссылки

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [EdDSA Signing](https://sparkle-project.org/documentation/eddsa/)
- [Appcast Format](https://sparkle-project.org/documentation/publishing/)
