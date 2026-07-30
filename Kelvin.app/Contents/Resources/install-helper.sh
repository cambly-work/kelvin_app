#!/bin/bash
# Ставит root-демон powermetrics для разбивки CPU/GPU/DRAM. Запускать через sudo.
set -e
if [ "$(id -u)" != "0" ]; then
    echo "Запусти через sudo:  sudo \"$0\"" ; exit 1
fi

SUPPORT="/Library/Application Support/Kelvin"
PLIST="/Library/LaunchDaemons/com.trykelvin.kelvin.powerd.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"   # папка Resources внутри .app

# Миграция BatteryMeter → Kelvin: убираем СТАРЫЙ демон/пути под прежним именем,
# чтобы переустановка хелпера не оставила осиротевший root-демон.
OLD_PLIST="/Library/LaunchDaemons/com.local.batterymeter.powerd.plist"
launchctl bootout system/com.local.batterymeter.powerd 2>/dev/null || true
launchctl unload "$OLD_PLIST" 2>/dev/null || true
rm -f "$OLD_PLIST"
rm -rf "/Library/Application Support/BatteryMeter"

echo "→ Копирую демон в $SUPPORT"
mkdir -p "$SUPPORT"
cp "$SRC/kelvin-powerd.sh" "$SUPPORT/kelvin-powerd.sh"
chown root:wheel "$SUPPORT/kelvin-powerd.sh"
chmod 755 "$SUPPORT/kelvin-powerd.sh"
printf '%s\n' "1" > "$SUPPORT/kelvin-powerd.sh.version"
chown root:wheel "$SUPPORT/kelvin-powerd.sh.version"
chmod 644 "$SUPPORT/kelvin-powerd.sh.version"

echo "→ Устанавливаю LaunchDaemon"
cp "$SRC/com.trykelvin.kelvin.powerd.plist" "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "→ Перезапускаю демон"
launchctl bootout system/com.trykelvin.kelvin.powerd 2>/dev/null || true
rm -f "$SUPPORT/power.txt" "$SUPPORT/power.txt.tmp"
if ! launchctl bootstrap system "$PLIST"; then
    echo "✗ launchd не принял модуль метрик." >&2
    exit 1
fi
launchctl enable system/com.trykelvin.kelvin.powerd
launchctl kickstart -k system/com.trykelvin.kelvin.powerd
if ! launchctl print system/com.trykelvin.kelvin.powerd | grep -q "state = running"; then
    echo "✗ Модуль метрик зарегистрирован, но не запустился." >&2
    launchctl bootout system/com.trykelvin.kelvin.powerd 2>/dev/null || true
    exit 1
fi

i=0
while [ "$i" -lt 10 ] && [ ! -s "$SUPPORT/power.txt" ]; do
    sleep 1
    i=$((i + 1))
done
if [ ! -s "$SUPPORT/power.txt" ]; then
    echo "✗ Модуль запущен, но не получил данные powermetrics." >&2
    echo "  Диагностика: $SUPPORT/powermetrics.err" >&2
    launchctl bootout system/com.trykelvin.kelvin.powerd 2>/dev/null || true
    exit 1
fi
echo "✓ Готово. Модуль пишет данные — в поповере появится детализация мощности."
