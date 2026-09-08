#!/bin/bash
# Собирает распространяемый DMG из Kelvin.app: перетащи-в-Программы.
# По умолчанию — DMG с оформлением Finder (фон окна, раскладка иконок, иконка тома).
# STYLE_DMG=0 — отключает Finder-оформление (голое окно, для CI/тестов).
set -euo pipefail
cd "$(dirname "$0")"

# Опциональный env: STYLE_DMG=0 отключает Finder-оформление (для CI/тестов).
# По умолчанию — стилизованный DMG. Default обязателен при `set -u`.
STYLE_DMG="${STYLE_DMG:-1}"

APP="Kelvin.app"
VOL="Kelvin"
[ -d "$APP" ] || { echo "✗ Нет $APP — сначала ./build.sh"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.9.0")
DMG="Kelvin-$VERSION.dmg"
WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"

echo "→ Готовлю содержимое ($VERSION)…"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# В beta-образе подготовка видима как первый шаг установки.
CMD="1. Prepare Kelvin.command"
if [ -f clean-old-version.sh ]; then
    cp clean-old-version.sh "$STAGE/$CMD"
    chmod +x "$STAGE/$CMD"
    # Finder показывает короткое имя без технического суффикса .command.
    command -v SetFile >/dev/null 2>&1 && SetFile -a E "$STAGE/$CMD" 2>/dev/null || true
else
    echo "  (внимание: clean-old-version.sh не найден — $CMD не добавлен)"
    CMD=""
fi
FIX_CMD="2. Fix quarantine.command"
if [ -f fix-quarantine.command ]; then
    cp fix-quarantine.command "$STAGE/$FIX_CMD"
    chmod +x "$STAGE/$FIX_CMD"
    # Второй шаг нужен только для неподписанной/notarized локальной сборки.
    command -v SetFile >/dev/null 2>&1 && SetFile -a E "$STAGE/$FIX_CMD" 2>/dev/null || true
else
    echo "  (внимание: fix-quarantine.command не найден — $FIX_CMD не добавлен)"
    FIX_CMD=""
fi
if [ -f Resources/dmg-bg.png ]; then
    mkdir -p "$STAGE/.background"
    cp Resources/dmg-bg.png "$STAGE/.background/bg.png"
    [ -f Resources/dmg-bg@2x.png ] && cp Resources/dmg-bg@2x.png "$STAGE/.background/bg@2x.png"
fi

echo "→ Создаю образ…"
rm -f "$DMG"
# read-write образ → иконка тома (+ опц. стилизация) → сжатый read-only
SIZE=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size "${SIZE}m" -ov "$RW" >/dev/null
MNT=$(hdiutil attach "$RW" -nobrowse -noautoopen -noverify | grep -o '/Volumes/.*' | head -1)
[ -n "$MNT" ] || { echo "✗ не примонтировался"; exit 1; }
# Если другой Kelvin.dmg уже открыт, macOS монтирует новый как "Kelvin 1/2…".
# Finder нужно адресовать по фактическому mount point, иначе стилизуется старый том.
FINDER_DISK="$(basename "$MNT")"

# иконка тома (без Finder)
if [ -f Resources/AppIcon.icns ] && command -v SetFile >/dev/null 2>&1; then
    cp Resources/AppIcon.icns "$MNT/.VolumeIcon.icns"
    SetFile -a C "$MNT" 2>/dev/null || true
fi

# Finder-стилизация (окно/иконки/фон) — по умолчанию. Отключается через STYLE_DMG=0.
if [ "$STYLE_DMG" != "0" ]; then
    echo "→ Раскладываю окно через Finder…"
    # Экранируем значения для строкового литерала AppleScript: \ и " могут быть в
    # FINDER_DISK (если уже смонтирован «Kelvin 1» с пробелом/кавычкой в basename).
    esc_app() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    ESC_DISK=$(esc_app "$FINDER_DISK")
    ESC_APP=$(esc_app "$APP")
    if [ -n "$CMD" ]; then
        ESC_CMD=$(esc_app "$CMD")
        PREP_POS="set position of item \"$ESC_CMD\" of container window to {150, 275}"
    else
        PREP_POS=""
    fi
    if [ -n "$FIX_CMD" ]; then
        ESC_FIX_CMD=$(esc_app "$FIX_CMD")
        FIX_POS="set position of item \"$ESC_FIX_CMD\" of container window to {450, 430}"
    else
        FIX_POS=""
    fi
    osascript <<EOF || echo "  (стилизация пропущена)"
tell application "Finder"
    tell disk "$ESC_DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {120, 100, 1020, 620}
        set vopts to the icon view options of container window
        set arrangement of vopts to not arranged
        set icon size of vopts to 104
        set background picture of vopts to file ".background:bg.png"
        $PREP_POS
        set position of item "$ESC_APP" of container window to {450, 275}
        set position of item "Applications" of container window to {750, 275}
        $FIX_POS
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
    sync
fi

sync
hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null 2>&1
echo "→ Сжимаю…"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$WORK"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
