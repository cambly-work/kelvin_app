#!/bin/bash
# Сборка Kelvin.app из исходников (нужны только Command Line Tools).
set -e
cd "$(dirname "$0")"

APP="Kelvin.app"
BIN="Kelvin"

echo "→ Компиляция…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# main.swift должен идти последним (в нём top-level код)
SRCS=$(ls Sources/*.swift | grep -v '/main.swift$')
xcrun swiftc -O $SRCS Sources/main.swift -o "$APP/Contents/MacOS/$BIN"
# страховка от «тихой» неудачи: swiftc, убитый по OOM (SIGKILL), может оставить пустой бандл при exit 0
[ -x "$APP/Contents/MacOS/$BIN" ] || { echo "✗ бинарь не собрался (пустой бандл — вероятно OOM)"; exit 1; }
strip -x "$APP/Contents/MacOS/$BIN" 2>/dev/null || true   # снять локальные символы: `nm` больше не выдаёт локатор гейта (isPro)

echo "→ Демон вентиляторов (fand)…"
xcrun swiftc -O Sources/SMCReader.swift helper/fand.swift -o "$APP/Contents/Resources/kelvin-fand" \
    && echo "  ✓ kelvin-fand" || echo "  ✗ демон не собрался"
strip -x "$APP/Contents/Resources/kelvin-fand" 2>/dev/null || true

cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# офлайн-гео (DB-IP country-lite, скомпактировано): флаг страны для подключений без сетевых запросов
[ -f Resources/geoip4.bin ] && cp Resources/geoip4.bin "$APP/Contents/Resources/"
[ -f Resources/geoip6.bin ] && cp Resources/geoip6.bin "$APP/Contents/Resources/"
[ -d THIRD_PARTY_NOTICES ] && cp -R THIRD_PARTY_NOTICES "$APP/Contents/Resources/"
cp helper/*.sh "$APP/Contents/Resources/" 2>/dev/null || true
[ -f helper/com.trykelvin.kelvin.powerd.plist ] && cp helper/com.trykelvin.kelvin.powerd.plist "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh 2>/dev/null || true

echo "→ Ad-hoc подпись…"
# A plain ad-hoc signature gets an implicit cdhash-based designated requirement.
# That cdhash changes on every build, so TCC treats each local Kelvin build as a
# different app and repeatedly drops Accessibility permission. An explicit,
# stable requirement keeps local development builds tied to the bundle ID.
codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.trykelvin.kelvin"' \
    "$APP" 2>/dev/null || echo "  (подпись пропущена)"

echo "✓ Готово: $(pwd)/$APP"
