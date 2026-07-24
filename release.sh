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

# appcast для собственного апдейтера (Updater.swift). DOWNLOAD_BASE — где хостятся DMG.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "11.0")
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://trykelvin.com}"
cat > docs/appcast.json <<JSON
{
  "version": "$VERSION",
  "url": "$DOWNLOAD_BASE/$DMG",
  "minOS": "$MINOS",
  "notes": "$DOWNLOAD_BASE/notes.html"
}
JSON
echo "  ✓ docs/appcast.json → $VERSION"

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
