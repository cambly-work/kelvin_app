#!/bin/bash
# Сборка Kelvin.app из исходников (нужны только Command Line Tools).
set -e
cd "$(dirname "$0")"

FINAL_APP="$PWD/Kelvin.app"
BIN="Kelvin"
STAGE_ROOT=$(mktemp -d)
APP="$STAGE_ROOT/Kelvin.app"
cleanup() { rm -rf "$STAGE_ROOT"; }
trap cleanup EXIT

echo "→ Компиляция…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

# main.swift должен идти последним (в нём top-level код)
SRCS=$(ls Sources/*.swift | grep -v '/main.swift$')
# Universal Binary: swiftc не поддерживает несколько -arch, компилируем отдельно + lipo
ARCHS="x86_64 arm64"
TMPDIR_BUILD=$(mktemp -d)
for arch in $ARCHS; do
    xcrun swiftc -O -target "$arch-apple-macos11" -F "$PWD" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks $SRCS Sources/main.swift -o "$TMPDIR_BUILD/$BIN-$arch" || { echo "✗ бинарь не собрался для $arch"; rm -rf "$TMPDIR_BUILD"; exit 1; }
done
lipo -create -output "$APP/Contents/MacOS/$BIN" $TMPDIR_BUILD/$BIN-x86_64 $TMPDIR_BUILD/$BIN-arm64
rm -rf "$TMPDIR_BUILD"
# страховка от «тихой» неудачи: swiftc, убитый по OOM (SIGKILL), может оставить пустой бандл при exit 0
[ -x "$APP/Contents/MacOS/$BIN" ] || { echo "✗ бинарь не собрался (пустой бандл — вероятно OOM)"; exit 1; }
strip -x "$APP/Contents/MacOS/$BIN" 2>/dev/null || true   # снять локальные символы: `nm` больше не выдаёт локатор гейта (isPro)

echo "→ Копирование Sparkle.framework…"
# Копируем Sparkle.framework в бандл (Universal Binary уже внутри)
cp -R "Sparkle.framework" "$APP/Contents/Frameworks/"
# Sparkle содержит вложенные исполняемые компоненты. Подписываем изнутри наружу:
# один --deep не переподписывает уже подписанные upstream-компоненты после копирования.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_CURRENT="$SPARKLE/Versions/Current"
codesign --force --sign - "$SPARKLE_CURRENT/Autoupdate"
codesign --force --deep --sign - "$SPARKLE_CURRENT/XPCServices/Downloader.xpc"
codesign --force --deep --sign - "$SPARKLE_CURRENT/XPCServices/Installer.xpc"
codesign --force --deep --sign - "$SPARKLE_CURRENT/Updater.app"
codesign --force --sign - "$SPARKLE"
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

echo "→ Privileged XPC-сервис (GPU switching)…"
# Universal Binary для privileged helper
TMPDIR_PRIV=$(mktemp -d)
for arch in $ARCHS; do
    xcrun swiftc -O -target "$arch-apple-macos11" helper/privileged/main.swift -o "$TMPDIR_PRIV/privileged-$arch" \
        && echo "  ✓ privileged ($arch)" || { echo "  ✗ privileged-сервис не собрался для $arch"; rm -rf "$TMPDIR_PRIV"; exit 1; }
done
lipo -create -output "$APP/Contents/Resources/kelvin-privileged" $TMPDIR_PRIV/privileged-x86_64 $TMPDIR_PRIV/privileged-arm64
rm -rf "$TMPDIR_PRIV"
strip -x "$APP/Contents/Resources/kelvin-privileged" 2>/dev/null || true
# Версия протокола — для update detection
echo "1" > "$APP/Contents/Resources/kelvin-privileged.version"

cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# офлайн-гео (DB-IP country-lite, скомпактировано): флаг страны для подключений без сетевых запросов
[ -f Resources/geoip4.bin ] && cp Resources/geoip4.bin "$APP/Contents/Resources/"
[ -f Resources/geoip6.bin ] && cp Resources/geoip6.bin "$APP/Contents/Resources/"
[ -d THIRD_PARTY_NOTICES ] && cp -R THIRD_PARTY_NOTICES "$APP/Contents/Resources/"
cp helper/*.sh "$APP/Contents/Resources/" 2>/dev/null || true
[ -f helper/com.trykelvin.kelvin.powerd.plist ] && cp helper/com.trykelvin.kelvin.powerd.plist "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh 2>/dev/null || true

# Privileged GPU daemon: plist + binary в Contents/Library/LaunchDaemons/
# SMAppService.daemon(plistName:) ищет plist именно там (macOS 13+).
# SMJobBless (macOS 11-12) тоже читает plist из этого locations.
echo "→ Privileged daemon plist в LaunchDaemons…"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp helper/privileged/com.trykelvin.kelvin.privileged.plist "$APP/Contents/Library/LaunchDaemons/"
# Копируем бинарь в LaunchDaemons (SMAppService запускает daemon из бандла)
cp "$APP/Contents/Resources/kelvin-privileged" "$APP/Contents/Library/LaunchDaemons/com.trykelvin.kelvin.privileged"

# A nested helper needs its own stable signing identifier. The XPC client
# verifies this identifier before trusting the privileged endpoint.
codesign --force --sign - \
    --identifier "com.trykelvin.kelvin.privileged" \
    "$APP/Contents/Library/LaunchDaemons/com.trykelvin.kelvin.privileged"

echo "→ Ad-hoc подпись…"
# A plain ad-hoc signature gets an implicit cdhash-based designated requirement.
# That cdhash changes on every build, so TCC treats each local Kelvin build as a
# different app and repeatedly drops Accessibility permission. An explicit,
# stable requirement keeps local development builds tied to the bundle ID.
codesign --force --sign - \
    --requirements '=designated => identifier "com.trykelvin.kelvin"' \
    "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$FINAL_APP"
mv "$APP" "$FINAL_APP"
echo "✓ Готово: $FINAL_APP"
