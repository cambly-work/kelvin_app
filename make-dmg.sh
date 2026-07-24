#!/bin/bash
# Собирает распространяемый DMG из Kelvin.app: перетащи-в-Программы.
# По умолчанию — функциональный DMG (app + симлинк /Applications + иконка тома), без Finder.
# STYLE_DMG=1 — дополнительно раскладывает иконки и ставит фон через Finder (для финального релиза).
set -e
cd "$(dirname "$0")"

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

# иконка тома (без Finder)
if [ -f Resources/AppIcon.icns ] && command -v SetFile >/dev/null 2>&1; then
    cp Resources/AppIcon.icns "$MNT/.VolumeIcon.icns"
    SetFile -a C "$MNT" 2>/dev/null || true
fi

# опциональная Finder-стилизация (окно/иконки/фон). Драйвит Finder — поэтому только по флагу.
if [ "$STYLE_DMG" = "1" ]; then
    echo "→ Раскладываю окно через Finder…"
    osascript <<EOF || echo "  (стилизация пропущена)"
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set vopts to the icon view options of container window
        set arrangement of vopts to not arranged
        set icon size of vopts to 110
        set background picture of vopts to file ".background:bg.png"
        set position of item "$APP" of container window to {165, 200}
        set position of item "Applications" of container window to {495, 200}
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
