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

echo "→ Устанавливаю LaunchDaemon"
cp "$SRC/com.trykelvin.kelvin.powerd.plist" "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "→ Перезапускаю демон"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

sleep 2
if [ -s "$SUPPORT/power.txt" ]; then
    echo "✓ Готово. Демон пишет данные — в поповере появится «Расход по железу»."
else
    echo "⚠ Демон загружен, но файл ещё пуст. Подожди пару секунд и открой поповер."
    echo "  Лог ошибок: /var/log/kelvin-powerd.err"
fi
