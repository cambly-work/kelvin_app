#!/bin/bash
# Удаляет демон управления вентиляторами и возвращает системный авто-режим. Через sudo.
#
# Точечный деинсталлятор только для fand. Полная очистка всех служб Kelvin/BatteryMeter
# (включая этот) — см. clean-old-version.sh в корне репозитория (единый allowlist целей).
if [ "$(id -u)" != "0" ]; then echo "Запусти через sudo:  sudo \"$0\""; exit 1; fi
PLIST="/Library/LaunchDaemons/com.trykelvin.kelvin.fand.plist"
launchctl bootout system/com.trykelvin.kelvin.fand 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true   # SIGTERM → демон вернёт авто-режим
# Миграция BatteryMeter → Kelvin: подчищаем и СТАРЫЙ демон вентиляторов под прежним именем.
launchctl bootout system/com.local.batterymeter.fand 2>/dev/null || true
launchctl unload "/Library/LaunchDaemons/com.local.batterymeter.fand.plist" 2>/dev/null || true
sleep 1
rm -f "$PLIST" "/Library/LaunchDaemons/com.local.batterymeter.fand.plist" \
    "/Library/Application Support/Kelvin/kelvin-fand" \
    "/Library/Application Support/Kelvin/kelvin-fand.version" \
    "/Library/Application Support/BatteryMeter/batterymeter-fand"
echo "✓ Демон вентиляторов удалён. Вентиляторы в системном авто-режиме."
