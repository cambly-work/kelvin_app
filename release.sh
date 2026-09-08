#!/bin/bash
# Полный релизный пайплайн Kelvin: сборка → подпись Developer ID + hardened runtime → DMG → нотаризация → staple.
#
# Параметры через переменные окружения:
#   DEVID_APP="Developer ID Application: Имя Фамилия (TEAMID)"
#       сертификат подписи. Без него — ad-hoc подпись, DMG будет НЕ нотаризован
#       (Gatekeeper покажет покупателю «неустановленный разработчик»).
#   AC_PROFILE="имя-профиля-notarytool"
#       профиль учётки Apple для нотаризации. Создаётся один раз:
#       xcrun notarytool store-credentials "имя-профиля" --apple-id you@mail --team-id TEAMID --password app-spec-pass
#       Без него — нотаризация пропускается.
#   STYLE_DMG=1  — стилизовать окно DMG через Finder (см. make-dmg.sh).
#   SPARKLE_ED_KEY_FILE=/path/to/private_ed_key  — экспортированный bin/generate_keys
#       bare-base64 ключ либо update_keys.txt со строками PRIVATE_KEY=/PUBLIC_KEY=.
#   SPARKLE_ED_PRIVATE_KEY="<base64>"  — альтернативно, приватный seed из env
#   SUPUBLIC_ED_KEY="<base64>"         — публичный ключ при bare private key/env
set -euo pipefail
cd "$(dirname "$0")"

# Опциональные переменные окружения: задаём пустые значения по умолчанию, чтобы
# `set -u` не обрывал скрипт при `[ -n "$VAR" ]` на необязательных параметрах.
# Команда релиза экспортирует нужные значения; без них сборка падает на ad-hoc/
# локальный режим (см. ветки `if [ -n ... ]` ниже). `${VAR:-}` здесь — safest pattern.
DEVID_APP="${DEVID_APP:-}"
AC_PROFILE="${AC_PROFILE:-}"
SPARKLE_ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-}"
SPARKLE_ED_PRIVATE_KEY="${SPARKLE_ED_PRIVATE_KEY:-}"
SUPUBLIC_ED_KEY="${SUPUBLIC_ED_KEY:-}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://trykelvin.com}"

echo "━━ 1/4  Сборка ━━"

# Production-активация проверок код-подписи: при наличии DEVID_APP вписываем
# извлечённый Team ID в helper/privileged/main.swift и Sources/AppConfig.swift
# ПЕРЕД сборкой, чтобы собранный бинарник содержал встроенный Team ID (это
# включает fail-closed валидацию клиентов XPC-сервисом и клиентом, а также
# anti-tamper self-check). Исходники восстанавливаются после сборки через trap.
TEAM_ID=""
if [ -n "$DEVID_APP" ]; then
    TEAM_ID=$(echo "$DEVID_APP" | grep -oE '\([A-Z0-9]{10}\)$' | tr -d '()' || true)
    if [ -z "$TEAM_ID" ]; then
        echo "✗ Не удалось извлечь Team ID из DEVID_APP."
        echo "  Ожидаемый формат: Developer ID Application: Name (ABCDE12345)"
        echo "  Production-сборка без строгой XPC identity validation запрещена."
        exit 1
    fi
fi
INJECT_FILES=""
if [ -n "$TEAM_ID" ]; then
    sed -i.tmp "s/let EXPECTED_TEAM_ID: String? = nil/let EXPECTED_TEAM_ID: String? = \"$TEAM_ID\"/" helper/privileged/main.swift
    sed -i.tmp "s/static let expectedDeveloperTeamID: String? = nil/static let expectedDeveloperTeamID: String? = \"$TEAM_ID\"/" Sources/AppConfig.swift
    INJECT_FILES="helper/privileged/main.swift Sources/AppConfig.swift"
    # Восстановление исходников после сборки (независимо от успеха).
    trap 'for f in $INJECT_FILES; do [ -f "$f.tmp" ] && mv -f "$f.tmp" "$f"; done' EXIT
    echo "  ✓ Team ID $TEAM_ID встроен в исходники (проверки XPC активированы)"
fi
export KELVIN_TEAM_ID="$TEAM_ID"

# release-сборка: отключаем DEBUG (BM_* overrides не должны работать в проде).
export KELVIN_RELEASE=1
./build.sh

# Жёсткий гейт: юнит-тесты чистой логики + полнота локализации. Мис-кламп BCLM = вред АКБ,
# пропущенный перевод = сломанная не-RU сборка — обе вещи нельзя выпускать.
echo "━━ Тесты (гейт) ━━"
./test/run-tests.sh

APP="Kelvin.app"
ENTITLEMENTS="Kelvin.entitlements"

# Перед релизом bundle id обязан быть доменным (Developer ID + нотаризация): com.local.* не пройдёт.
if [ -n "$DEVID_APP" ]; then
    BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
    if [[ "$BID" == com.local.* ]]; then
        echo "  ✗ Bundle id «$BID» начинается с com.local.* — смени на доменный (br.com.kelvin) синхронно с labels демонов перед релизом."
        exit 1
    fi
fi

if [ -n "$DEVID_APP" ]; then
    echo "━━ 2/4  Подпись Developer ID + hardened runtime ━━"

    # Fail-closed gate: Privileged GPU Service требует Team ID для client validation.
    # Без него привилегированный сервис принимает ad-hoc подпись — небезопасно для production.
    # Сначала вложенные Mach-O (демон fand, privileged-сервис и пр.), затем сам бандл — БЕЗ --deep.
    # (фильтр Mach-O делает grep; -type f без -perm — портируемо между BSD/GNU find)
    while IFS= read -r f; do
        if file "$f" | grep -q "Mach-O"; then
            codesign --force --options runtime --timestamp --sign "$DEVID_APP" "$f"
            echo "  ✓ подписан $(basename "$f")"
        fi
    done < <(find "$APP/Contents/Resources" -type f)

    # Вложенный privileged GPU-демон в Contents/Library/LaunchDaemons требует той же
    # Developer ID-подписи + hardened runtime: SMAppService проверяет подпись бандла,
    # а XPC client-side верификация требует identifier "com.trykelvin.kelvin.privileged".
    # build.sh подписывает его ad-hoc; здесь переподписываем сертификатом релиза.
    PRIV_DAEMON="$APP/Contents/Library/LaunchDaemons/com.trykelvin.kelvin.privileged"
    BLESS_HELPER="$APP/Contents/Library/LaunchServices/com.trykelvin.kelvin.privileged"
    if [ -f "$PRIV_DAEMON" ]; then
        codesign --force --options runtime --timestamp \
            --identifier "com.trykelvin.kelvin.privileged" \
            --sign "$DEVID_APP" "$PRIV_DAEMON"
        echo "  ✓ подписан privileged GPU-демон (Developer ID + hardened runtime)"
    fi
    if [ -f "$BLESS_HELPER" ]; then
        codesign --force --options runtime --timestamp \
            --identifier "com.trykelvin.kelvin.privileged" \
            --sign "$DEVID_APP" "$BLESS_HELPER"
        echo "  ✓ подписан SMJobBless helper для macOS 11–12"
    fi
    # Главный бандл — С entitlements (иначе Apple Events падают под hardened runtime в нотаризованной сборке).
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID_APP" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "  ✓ бандл подписан (с entitlements) и проверен"

    # Верификация вложенного privileged-демона: Team ID и identity должны соответствовать
    # приложению. Проверяем глубокую подпись бандла и отдельно daemon.
    if [ -f "$PRIV_DAEMON" ]; then
        codesign --verify --strict --verbose=2 "$PRIV_DAEMON"
        codesign -dvvv "$PRIV_DAEMON" 2>&1 | grep -qE "Identifier=com.trykelvin.kelvin.privileged" \
            || { echo "  ✗ identifier privileged-демона не соответствует ожидаемому."; exit 1; }
        if [ -f "$PRIV_DAEMON.plist" ]; then
            plutil -lint "$PRIV_DAEMON.plist" >/dev/null \
                || { echo "  ✗ plist privileged-демона невалиден."; exit 1; }
        fi
        echo "  ✓ privileged-демон проверен (identity + plist)"
    fi
    if [ -f "$BLESS_HELPER" ]; then
        codesign --verify --strict --verbose=2 "$BLESS_HELPER"
        codesign -dvvv "$BLESS_HELPER" 2>&1 | grep -qE "Identifier=com.trykelvin.kelvin.privileged" \
            || { echo "  ✗ identifier SMJobBless helper не соответствует ожидаемому."; exit 1; }
        echo "  ✓ SMJobBless helper проверен"
    fi
else
    echo "━━ 2/4  Подпись пропущена ━━"
    echo "  ⚠ DEVID_APP не задан → ad-hoc подпись. DMG нельзя нотаризовать —"
    echo "    Gatekeeper заблокирует у пользователя. Для релиза задай DEVID_APP."
fi

echo "━━ 3/4  Сборка DMG ━━"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "11.0")
UPDATE_ARCHIVE="Kelvin-${VERSION}.zip"

# Сначала получаем ОБА EdDSA-ключа. Публичный ключ должен попасть в app ДО
# упаковки DMG/ZIP; иначе локальный Kelvin.app изменится, а распространяемые
# артефакты навсегда останутся без SUPublicEDKey.
#
# Форматы ключей:
#   SPARKLE_ED_KEY_FILE   — bare-base64 export generate_keys -x либо paired update_keys.txt
#   SPARKLE_ED_PRIVATE_KEY — bare base64 приватного ключа (одной строкой)
#   SUPUBLIC_ED_KEY        — bare base64 публичного ключа (для явного override)
# Официальный sign_update принимает bare-base64 приватный seed через stdin и не
# печатает pubkey, поэтому публичный ключ получаем отдельно из paired-файла/env.
ED_SIGNATURE=""
ED_PUBKEY="${SUPUBLIC_ED_KEY:-}"
ED_PRIVATE=""

# Извлекаем приватный ключ: из файла (парсим PRIVATE_KEY=) или из env (bare base64).
if [ -n "$SPARKLE_ED_KEY_FILE" ] && [ -f "$SPARKLE_ED_KEY_FILE" ]; then
    if grep -q '^PRIVATE_KEY=' "$SPARKLE_ED_KEY_FILE"; then
        ED_PRIVATE=$(grep '^PRIVATE_KEY=' "$SPARKLE_ED_KEY_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')
        # Публичный ключ — из того же paired-файла (если не задан через env).
        if [ -z "$ED_PUBKEY" ]; then
            ED_PUBKEY=$(grep '^PUBLIC_KEY=' "$SPARKLE_ED_KEY_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')
        fi
    else
        # Нативный `generate_keys -x`: файл содержит только bare base64 private seed.
        ED_PRIVATE=$(tr -d '[:space:]' < "$SPARKLE_ED_KEY_FILE")
    fi
elif [ -n "$SPARKLE_ED_PRIVATE_KEY" ]; then
    ED_PRIVATE="$SPARKLE_ED_PRIVATE_KEY"
fi

# Developer ID-релиз обязан иметь полную Sparkle trust chain.
if [ -n "$DEVID_APP" ] && { [ -z "$ED_PRIVATE" ] || [ -z "$ED_PUBKEY" ]; }; then
    echo "✗ Для production-релиза нужны приватный И публичный EdDSA-ключи Sparkle."
    echo "  Задайте SPARKLE_ED_KEY_FILE с PRIVATE_KEY/PUBLIC_KEY либо соответствующие env."
    exit 1
fi

# Вшиваем публичный ключ до создания любых распространяемых артефактов.
if [ -n "$ED_PUBKEY" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $ED_PUBKEY" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $ED_PUBKEY" "$APP/Contents/Info.plist"
    echo "  ✓ SUPublicEDKey вшит в Info.plist собранного бандла"
    # Info.plist входит в подпись: переподписываем до копирования в DMG/ZIP.
    if [ -n "$DEVID_APP" ]; then
        codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID_APP" "$APP"
    else
        codesign --force --sign - \
            --requirements '=designated => identifier "com.trykelvin.kelvin"' \
            "$APP"
    fi
    codesign --verify --strict "$APP"
    echo "  ✓ Бандл переподписан и проверен после вшивания SUPublicEDKey"
else
    echo "  ⚠ Публичный EdDSA-ключ не получен → SUPublicEDKey не вшит."
    echo "    Задайте SUPUBLIC_ED_KEY или SPARKLE_ED_KEY_FILE (с PUBLIC_KEY= строкой)."
fi

# Только теперь копируем финальный подписанный app в DMG и update ZIP.
./make-dmg.sh
DMG=$(ls -t Kelvin-*.dmg | head -1)
[ -n "$DEVID_APP" ] && codesign --force --timestamp --sign "$DEVID_APP" "$DMG" && echo "  ✓ DMG подписан"

echo "  → Создание update archive: $UPDATE_ARCHIVE"
ditto -c -k --keepParent "$APP" "$UPDATE_ARCHIVE"

# Подписываем уже финальный архив EdDSA-ключом.
if [ -n "$ED_PRIVATE" ] && [ -n "$ED_PUBKEY" ]; then
    # Используем официальный Sparkle signer. Самописная реализация раньше
    # подписывала SHA-256 digest вместо содержимого архива и была несовместима
    # с проверкой Sparkle; вдобавок релиз молча зависел от внешнего PyNaCl.
    SIGN_OUT=$(printf '%s' "$ED_PRIVATE" | ./bin/sign_update --ed-key-file - "$UPDATE_ARCHIVE" 2>/dev/null || true)
    ED_SIGNATURE=$(echo "$SIGN_OUT" | grep 'sparkle:edSignature' | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')
    if [ -n "$ED_SIGNATURE" ]; then
        echo "  ✓ Update archive подписан EdDSA"
    elif [ -n "$DEVID_APP" ]; then
        echo "✗ Не удалось подписать update archive (проверь формат приватного ключа)."
        exit 1
    else
        echo "  ⚠ Не удалось подписать архив (локальная сборка)"
    fi
else
    echo "  ⚠ EdDSA-ключи не заданы → локальный архив НЕ подписан"
fi

# Вычисляем размер архива
ARCHIVE_SIZE=$(stat -f%z "$UPDATE_ARCHIVE" 2>/dev/null || stat -c%s "$UPDATE_ARCHIVE" 2>/dev/null || echo "0")

# Генерируем appcast.xml
cat > docs/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kelvin Updates</title>
    <description>Latest updates for Kelvin</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <releaseNotesLink>${DOWNLOAD_BASE}/notes.html</releaseNotesLink>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <enclosure
          url="${DOWNLOAD_BASE}/${UPDATE_ARCHIVE}"
          sparkle:version="$BUILD"
          sparkle:shortVersionString="$VERSION"
          sparkle:minimumSystemVersion="$MINOS"
          length="$ARCHIVE_SIZE"
          type="application/zip"
${ED_SIGNATURE:+          sparkle:edSignature=\"$ED_SIGNATURE\"}
      />
    </item>
  </channel>
</rss>
XML
echo "  ✓ docs/appcast.xml → $VERSION (build $BUILD)"

echo "━━ 4/4  Нотаризация ━━"
if [ -n "$DEVID_APP" ] && [ -n "$AC_PROFILE" ]; then
    echo "  → Отправляю $DMG в Apple (ждём вердикт)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$AC_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "  ✓ $DMG — нотаризован и заштаплен."

    # Sparkle update-архив (zip) — это то, что пользователи реально получают при
    # автообновлении. Нотаризуем и его, иначе автообновление обходит Gatekeeper.
    # Sparkle проверяет EdDSA-подпись archives, но нотаризация даёт второй рубеж
    # и согласованность с DMG-каналом распространения.
    echo "  → Отправляю $UPDATE_ARCHIVE в Apple (ждём вердикт)…"
    xcrun notarytool submit "$UPDATE_ARCHIVE" --keychain-profile "$AC_PROFILE" --wait
    xcrun stapler staple "$UPDATE_ARCHIVE" 2>/dev/null \
        && echo "  ✓ $UPDATE_ARCHIVE — нотаризован и заштаплен." \
        || echo "  ℹ staple zip пропущен (stapler поддерживает не все типы archives)."
    echo "✓ Готово: $DMG и $UPDATE_ARCHIVE — подписаны, нотаризованы. Можно публиковать."
else
    echo "  ℹ Пропущена (нужны DEVID_APP + AC_PROFILE)."
    echo "✓ Готово: $DMG и $UPDATE_ARCHIVE — НЕ нотаризованы (только для локальной проверки)."
fi
