#!/bin/bash
# Сборка Kelvin.app из исходников (нужны только Command Line Tools).
set -e
cd "$(dirname "$0")"

APP="Kelvin.app"
BIN="Kelvin"

echo "→ Компиляция…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

# main.swift должен идти последним (в нём top-level код)
SRCS=$(ls Sources/*.swift | grep -v '/main.swift$')
# Universal Binary: swiftc не поддерживает несколько -arch, компилируем отдельно + lipo
ARCHS="x86_64 arm64"
TMPDIR_BUILD=$(mktemp -d)
for arch in $ARCHS; do
    xcrun swiftc -O -target "$arch-apple-macos11" $SRCS Sources/main.swift -o "$TMPDIR_BUILD/$BIN-$arch" || { echo "✗ бинарь не собрался для $arch"; rm -rf "$TMPDIR_BUILD"; exit 1; }
done
lipo -create -output "$APP/Contents/MacOS/$BIN" $TMPDIR_BUILD/$BIN-x86_64 $TMPDIR_BUILD/$BIN-arm64
rm -rf "$TMPDIR_BUILD"
# страховка от «тихой» неудачи: swiftc, убитый по OOM (SIGKILL), может оставить пустой бандл при exit 0
[ -x "$APP/Contents/MacOS/$BIN" ] || { echo "✗ бинарь не собрался (пустой бандл — вероятно OOM)"; exit 1; }
strip -x "$APP/Contents/MacOS/$BIN" 2>/dev/null || true   # снять локальные символы: `nm` больше не выдаёт локатор гейта (isPro)

echo "→ Копирование Sparkle.framework…"
# Копируем Sparkle.framework в бандл (Universal Binary уже внутри)
cp -R "Sparkle.framework" "$APP/Contents/Frameworks/"
# Подписываем фреймворк ad-hoc для локальной сборки (в релизе подпишем Developer ID)
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
echo "  ✓ Sparkle.framework скопирован"

echo "→ Демон вентиляторов (fand)…"
# Universal Binary для fand
TMPDIR_FAND=$(mktemp -d)
for arch in $ARCHS; do
    xcrun swiftc -O -target "$arch-apple-macos11" Sources/IOKitCompat.swift Sources/SMCReader.swift helper/fand.swift -o "$TMPDIR_FAND/fand-$arch" \
        && echo "  ✓ fand ($arch)" || { echo "  ✗ демон не собрался для $arch"; rm -rf "$TMPDIR_FAND"; exit 1; }
done
lipo -create -output "$APP/Contents/Resources/kelvin-fand" $TMPDIR_FAND/fand-x86_64 $TMPDIR_FAND/fand-arm64
rm -rf "$TMPDIR_FAND"
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
