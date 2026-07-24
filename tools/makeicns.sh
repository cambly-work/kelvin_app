#!/bin/bash
# Рендерит мастер-PNG (tools/makeicon.swift) и собирает Resources/AppIcon.icns
# со всеми размерами. Запуск: ./tools/makeicns.sh
set -e
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
MASTER="$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "→ Рендер мастера 1024×1024…"
swiftc tools/makeicon.swift -o "$TMP/makeicon"
"$TMP/makeicon" "$MASTER" 1024 >/dev/null

echo "→ Размеры iconset…"
# Малые (≤64) рендерим НАПРЯМУЮ упрощённым путём makeicon (без рисок/виньетки — чётче, не в кашу).
"$TMP/makeicon" "$ICONSET/icon_16x16.png"     16  >/dev/null
"$TMP/makeicon" "$ICONSET/icon_16x16@2x.png"  32  >/dev/null
"$TMP/makeicon" "$ICONSET/icon_32x32.png"     32  >/dev/null
"$TMP/makeicon" "$ICONSET/icon_32x32@2x.png"  64  >/dev/null
# Крупные — даунскейл качественного мастера.
sips -z 128  128  "$MASTER" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$MASTER" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$MASTER" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

echo "→ iconutil → .icns…"
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
# PNG для сайта/превью
cp "$MASTER" Resources/AppIcon-1024.png
sips -z 512 512 "$MASTER" --out docs/assets/icon.png >/dev/null   # обновляем иконку лендинга

rm -rf "$TMP"
echo "✓ Resources/AppIcon.icns обновлён"
