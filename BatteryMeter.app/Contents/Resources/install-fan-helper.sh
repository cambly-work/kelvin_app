#!/bin/bash
# Ставит root-демон управления вентиляторами (fand). Запускать через sudo.
# Демон форсирует обороты по профилю из ~/Library/Application Support/BatteryMeter/fan-profile.json.
# Защита: перегрев → максимум; остановка/удаление демона → системный авто-режим.
set -e
if [ "$(id -u)" != "0" ]; then echo "Запусти через sudo:  sudo \"$0\""; exit 1; fi

RUSER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
RHOME=$(eval echo "~$RUSER")
SUPPORT="/Library/Application Support/BatteryMeter"
UDIR="$RHOME/Library/Application Support/BatteryMeter"
PROFILE="$UDIR/fan-profile.json"
PLIST="/Library/LaunchDaemons/com.local.batterymeter.fand.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "→ Копирую демон"
mkdir -p "$SUPPORT"
cp "$SRC/batterymeter-fand" "$SUPPORT/batterymeter-fand"
chown root:wheel "$SUPPORT/batterymeter-fand"
chmod 755 "$SUPPORT/batterymeter-fand"

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
    <key>Label</key><string>com.local.batterymeter.fand</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SUPPORT/batterymeter-fand</string>
        <string>--profile</string>
        <string>$PROFILE</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardErrorPath</key><string>/var/log/batterymeter-fand.err</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo "✓ Демон вентиляторов запущен."
echo "  Управление активирует выбранный в настройках профиль (кроме «Авто»)."
echo "  Защита: перегрев → максимум; «Авто» или удаление демона → системный режим."
