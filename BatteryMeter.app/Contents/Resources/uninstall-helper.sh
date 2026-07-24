#!/bin/bash
# Полностью удаляет root-демон powermetrics. Запускать через sudo.
if [ "$(id -u)" != "0" ]; then
    echo "Запусти через sudo:  sudo \"$0\"" ; exit 1
fi
PLIST="/Library/LaunchDaemons/com.local.batterymeter.powerd.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "/Library/Application Support/BatteryMeter"
echo "✓ Хелпер и демон удалены."
