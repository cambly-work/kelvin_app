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
#   SPARKLE_ED_KEY_FILE=/path/to/private_ed_key  — путь к файлу приватного EdDSA ключа Sparkle
#       Для подписи update-артефактов. Ключ генерируется через bin/generate_keys.
#   SPARKLE_ED_PRIVATE_KEY="-----BEGIN ED PRIVATE KEY-----..."  — альтернативно, ключ из env
set -e
cd "$(dirname "$0")"

echo "━━ 1/4  Сборка ━━"
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
    # Сначала вложенные Mach-O (демон fand и пр.), затем сам бандл — БЕЗ --deep.
    # (фильтр Mach-O делает grep; -type f без -perm — портируемо между BSD/GNU find)
    while IFS= read -r f; do
        if file "$f" | grep -q "Mach-O"; then
            codesign --force --options runtime --timestamp --sign "$DEVID_APP" "$f"
            echo "  ✓ подписан $(basename "$f")"
        fi
    done < <(find "$APP/Contents/Resources" -type f)
    # Главный бандл — С entitlements (иначе Apple Events падают под hardened runtime в нотаризованной сборке).
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID_APP" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "  ✓ бандл подписан (с entitlements) и проверен"
else
    echo "━━ 2/4  Подпись пропущена ━━"
    echo "  ⚠ DEVID_APP не задан → ad-hoc подпись. DMG нельзя нотаризовать —"
    echo "    Gatekeeper заблокирует у покупателя. Для релиза задай DEVID_APP."
fi

echo "━━ 3/4  Сборка DMG ━━"
./make-dmg.sh
DMG=$(ls -t Kelvin-*.dmg | head -1)
[ -n "$DEVID_APP" ] && codesign --force --timestamp --sign "$DEVID_APP" "$DMG" && echo "  ✓ DMG подписан"

# Appcast для Sparkle (XML с EdDSA подписью)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "11.0")
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://trykelvin.com}"

# Создаём archive для обновления (zip с app)
UPDATE_ARCHIVE="Kelvin-${VERSION}.zip"
echo "  → Создание update archive: $UPDATE_ARCHIVE"
ditto -c -k --keepParent "$APP" "$UPDATE_ARCHIVE"

# Подписываем архив EdDSA ключом (если есть приватный ключ)
ED_SIGNATURE=""
if [ -n "$SPARKLE_ED_KEY_FILE" ] && [ -f "$SPARKLE_ED_KEY_FILE" ]; then
    ED_SIGNATURE=$(./bin/sign_update --ed-key-file "$SPARKLE_ED_KEY_FILE" "$UPDATE_ARCHIVE" | grep -o '"edSignature":"[^"]*"' | cut -d'"' -f4)
    echo "  ✓ Update archive подписан EdDSA"
elif [ -n "$SPARKLE_ED_PRIVATE_KEY" ]; then
    # Альтернативно: ключ из переменной окружения
    echo "$SPARKLE_ED_PRIVATE_KEY" > /tmp/sparkle_ed_key.tmp
    ED_SIGNATURE=$(./bin/sign_update --ed-key-file /tmp/sparkle_ed_key.tmp "$UPDATE_ARCHIVE" | grep -o '"edSignature":"[^"]*"' | cut -d'"' -f4)
    rm -f /tmp/sparkle_ed_key.tmp
    echo "  ✓ Update archive подписан EdDSA (из env)"
else
    echo "  ⚠ SPARKLE_ED_KEY_FILE или SPARKLE_ED_PRIVATE_KEY не заданы → архив НЕ подписан"
    echo "    Для релиза задайте переменную с путём к приватному ключу."
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
    echo "✓ Готово: $DMG — подписан, нотаризован, заштаплен. Можно отдавать покупателям."
else
    echo "  ℹ Пропущена (нужны DEVID_APP + AC_PROFILE)."
    echo "✓ Готово: $DMG — НЕ нотаризован (только для локальной проверки)."
fi
