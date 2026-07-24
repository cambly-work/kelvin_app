#!/bin/bash
# Ставит root-демон powermetrics для разбивки CPU/GPU/DRAM. Запускать через sudo.
set -e
if [ "$(id -u)" != "0" ]; then
    echo "Запусти через sudo:  sudo \"$0\"" ; exit 1
fi

SUPPORT="/Library/Application Support/BatteryMeter"
PLIST="/Library/LaunchDaemons/com.local.batterymeter.powerd.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"   # папка Resources внутри .app

echo "→ Копирую демон в $SUPPORT"
mkdir -p "$SUPPORT"
cp "$SRC/batterymeter-powerd.sh" "$SUPPORT/batterymeter-powerd.sh"
chown root:wheel "$SUPPORT/batterymeter-powerd.sh"
chmod 755 "$SUPPORT/batterymeter-powerd.sh"

echo "→ Устанавливаю LaunchDaemon"
cp "$SRC/com.local.batterymeter.powerd.plist" "$PLIST"
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
    echo "  Лог ошибок: /var/log/batterymeter-powerd.err"
fi
