# Kelvin — playbook запуска

Код, монетизация, DMG-пайплайн, лендинг и автообновления готовы. Ниже — что осталось сделать руками,
чтобы начать продавать. Шаги 1–2 — длинные (аккаунты), запускать первыми.

Реквизиты проекта: **Artem Balabanov (MEI)** · CNPJ 53.294.776/0001-28 · cambly.studio@gmail.com

---

## 1. Apple Developer + нотаризация  ⏳ ~1–2 недели

Без этого DMG неподписан и Gatekeeper заблокирует приложение у покупателя.

1. **D-U-N-S Number** на CNPJ — бесплатно: https://developer.apple.com/enroll/duns-lookup/ (выдача ~1–2 нед).
2. **Apple Developer Program** как организация ($99/год): https://developer.apple.com/programs/enroll/
3. В Xcode/Developer-портале выпустить сертификат **Developer ID Application** → установить в Keychain.
4. Настроить notarytool один раз (нужен app-specific password из appleid.apple.com):
   ```sh
   xcrun notarytool store-credentials "kelvin-notary" \
       --apple-id cambly.studio@gmail.com --team-id <TEAMID> --password <app-spec-pass>
   ```

## 2. Магазин Lemon Squeezy  💳

1. Создать аккаунт → Store → продукт «Kelvin Pro», цена **$19**, тип **License keys** (single activation limit = 2).
2. Записать **store_id** и **product_id** (видны в URL/настройках продукта).
3. Вписать их в [Sources/Licensing.swift](Sources/Licensing.swift):
   ```swift
   static let storeID: Int? = <store_id>
   static let productID: Int? = <product_id>
   static let checkoutURL = "https://<твой-чекаут>.lemonsqueezy.com/checkout/..."
   ```
   После этого активация ключей в приложении заработает вживую (код готов, сейчас за `nil`-заглушкой).
4. На лендинге заменить плейсхолдер `https://trykelvin.com` (помечен `BUY_URL` в [docs/index.html](docs/index.html))
   на тот же checkout-URL.

## 3. Домен и хостинг

- **Лендинг + appcast + DMG**: проще всего GitHub Pages из папки `docs/` (бесплатно). Положить туда же `Kelvin-X.Y.dmg`.
- Домен: `kelvin.com.br` (под MEI) или префикс (trykelvin/usekelvin). Прописать в `Updater.feedURL`
  и `DOWNLOAD_BASE` совпадающими с реальным хостом.

## 4. Собрать релиз

```sh
DEVID_APP="Developer ID Application: Artem Balabanov (TEAMID)" \
AC_PROFILE="kelvin-notary" \
DOWNLOAD_BASE="https://<хост>" \
SPARKLE_ED_KEY_FILE=/secure/path/to/private_ed_key \
STYLE_DMG=1 \
./release.sh
```

Скрипт: сборка → подпись + hardened runtime → DMG (стилизованный) → нотаризация → staple →
создание update archive → подпись EdDSA → генерация `docs/appcast.xml`.
На выходе — `Kelvin-X.Y.dmg` и `Kelvin-X.Y.zip`, готовые к раздаче.

Без `DEVID_APP`/`AC_PROFILE` скрипт всё равно соберёт DMG (для локальной проверки), но без нотаризации.
Без `SPARKLE_ED_KEY_FILE` update archive не будет подписан — Sparkle откажется устанавливать обновление.

## 5. Опубликовать

1. Залить `Kelvin-X.Y.zip`, `docs/appcast.xml`, обновлённый `docs/` на хостинг.
2. Проверить ссылку «Купить» на лендинге и активацию тестовым ключом Lemon Squeezy.
3. Готово — можно вести трафик.

---

## Выпуск новой версии (потом)

1. Поднять `CFBundleShortVersionString` (и `CFBundleVersion`) в [Info.plist](Info.plist).
2. Добавить запись в [docs/notes.html](docs/notes.html).
3. Сгенерировать ключи EdDSA (если ещё не созданы): `./generate_update_keys.sh`
4. Вставить публичный ключ в `Info.plist` как `SUPublicEDKey`.
5. `./release.sh` с `SPARKLE_ED_KEY_FILE` → новый DMG + ZIP + подписанный `docs/appcast.xml`.
6. Залить на хостинг. Установленные приложения подхватят обновление через Sparkle (раз в сутки) и
   предложат установить внутри приложения.

### Подробный runbook

См. [UPDATE_RUNBOOK.md](UPDATE_RUNBOOK.md) — полная инструкция по:
- Выпуску обычных и критических обновлений
- Ротации ключей EdDSA
- Отзыву ошибочного релиза
- Временной остановке feed
- Rollback и восстановлению service
- Диагностике update failure
- Проверке совместимости privileged service

## Чем проверять до релиза (dev-флаги)

`BM_PRO` (активный Pro) · `BM_TRIAL_DAYS=N` · `BM_TRIALENDED` (прощальный оффер) ·
`BM_FREE` (бесплатное состояние) · `BM_FEED=<url>` (стейджинг appcast) · `BM_NOBATT` (десктоп без АКБ).
