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
# Не удаляем общий каталог Kelvin целиком: рядом живут независимый fand и его
# конфигурация. Старый uninstall оставлял plist fand без исполняемого файла.
rm -f "/Library/Application Support/Kelvin/kelvin-powerd.sh" \
      "/Library/Application Support/Kelvin/kelvin-powerd.sh.version" \
      "/Library/Application Support/Kelvin/power.txt" \
      "/Library/Application Support/Kelvin/power.txt.tmp" \
      "/Library/Application Support/Kelvin/powermetrics.err"
rm -rf "/Library/Application Support/BatteryMeter"
rmdir "/Library/Application Support/Kelvin" 2>/dev/null || true
echo "✓ Хелпер и демон удалены."
