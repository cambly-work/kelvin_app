#!/bin/bash
# Полностью удаляет root-демон powermetrics. Запускать через sudo.
if [ "$(id -u)" != "0" ]; then
    echo "Запусти через sudo:  sudo \"$0\"" ; exit 1
fi
PLIST="/Library/LaunchDaemons/com.trykelvin.kelvin.powerd.plist"
launchctl bootout system/com.trykelvin.kelvin.powerd 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
# Миграция BatteryMeter → Kelvin: подчищаем и СТАРЫЙ демон/пути под прежним именем.
launchctl bootout system/com.local.batterymeter.powerd 2>/dev/null || true
launchctl unload "/Library/LaunchDaemons/com.local.batterymeter.powerd.plist" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/com.local.batterymeter.powerd.plist"
rm -rf "/Library/Application Support/Kelvin" "/Library/Application Support/BatteryMeter"
echo "✓ Хелпер и демон удалены."
