#!/bin/bash
# Удаляет демон управления вентиляторами и возвращает системный авто-режим. Через sudo.
if [ "$(id -u)" != "0" ]; then echo "Запусти через sudo:  sudo \"$0\""; exit 1; fi
PLIST="/Library/LaunchDaemons/com.local.batterymeter.fand.plist"
launchctl unload "$PLIST" 2>/dev/null || true   # SIGTERM → демон вернёт авто-режим
sleep 1
rm -f "$PLIST" "/Library/Application Support/BatteryMeter/batterymeter-fand"
echo "✓ Демон вентиляторов удалён. Вентиляторы в системном авто-режиме."
