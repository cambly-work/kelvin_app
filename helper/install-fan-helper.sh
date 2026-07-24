#!/bin/bash
# Ставит root-демон управления вентиляторами (fand). Запускать через sudo.
# Демон форсирует обороты по профилю из ~/Library/Application Support/Kelvin/fan-profile.json.
# Защита: перегрев → максимум; остановка/удаление демона → системный авто-режим.
set -e
if [ "$(id -u)" != "0" ]; then echo "Запусти через sudo:  sudo \"$0\""; exit 1; fi

RUSER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
RHOME=$(eval echo "~$RUSER")
SUPPORT="/Library/Application Support/Kelvin"
UDIR="$RHOME/Library/Application Support/Kelvin"
PROFILE="$UDIR/fan-profile.json"
PLIST="/Library/LaunchDaemons/com.trykelvin.kelvin.fand.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"

# Миграция BatteryMeter → Kelvin: убираем СТАРЫЙ демон вентиляторов под прежним
# именем, чтобы переустановка хелпера не оставила осиротевший root-демон.
OLD_PLIST="/Library/LaunchDaemons/com.local.batterymeter.fand.plist"
launchctl bootout system/com.local.batterymeter.fand 2>/dev/null || true
launchctl unload "$OLD_PLIST" 2>/dev/null || true
rm -f "$OLD_PLIST" "/Library/Application Support/BatteryMeter/batterymeter-fand"

echo "→ Копирую демон"
mkdir -p "$SUPPORT"
cp "$SRC/kelvin-fand" "$SUPPORT/kelvin-fand"
chown root:wheel "$SUPPORT/kelvin-fand"
chmod 755 "$SUPPORT/kelvin-fand"

echo "→ Профиль: $PROFILE"
mkdir -p "$UDIR"
[ -f "$PROFILE" ] || echo '{"name":"Авто","mode":"auto"}' > "$PROFILE"
chown -R "$RUSER" "$UDIR" 2>/dev/null || true

echo "→ Устанавливаю LaunchDaemon"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.trykelvin.kelvin.fand</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SUPPORT/kelvin-fand</string>
        <string>--profile</string>
        <string>$PROFILE</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardErrorPath</key><string>/var/log/kelvin-fand.err</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo "✓ Демон вентиляторов запущен."
echo "  Управление активирует выбранный в настройках профиль (кроме «Авто»)."
echo "  Защита: перегрев → максимум; «Авто» или удаление демона → системный режим."
