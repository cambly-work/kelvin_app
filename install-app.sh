#!/bin/bash
# Ставит Kelvin.app в /Applications и добавляет в автозапуск (без sudo).
set -e
cd "$(dirname "$0")"

DEST="/Applications/Kelvin.app"
OLD_AGENT="$HOME/Library/LaunchAgents/com.local.batterymeter.plist"   # миграция BatteryMeter→Kelvin: кустарный автозапуск под старым именем (заменён на SMAppService)

echo "→ Копирую в /Applications"
pkill -x Kelvin 2>/dev/null || true
pkill -x BatteryMeter 2>/dev/null || true                          # старый бинарь, если остался
rm -rf "/Applications/BatteryMeter.app"                            # убрать старую сборку под прежним именем
rm -rf "$DEST"
cp -R Kelvin.app "$DEST"

# автозапуск теперь через SMAppService (login item, галочка в Настройках) — убираем старый LaunchAgent
if [ -f "$OLD_AGENT" ]; then
    echo "→ Убираю старый LaunchAgent (автозапуск переехал на login item)"
    launchctl unload "$OLD_AGENT" 2>/dev/null || true
    rm -f "$OLD_AGENT"
fi

echo "→ Запускаю Kelvin"
open "$DEST"   # приложение само перенесёт автозапуск на login item (разово)

echo "✓ Kelvin установлен в /Applications."
echo "  Иконка 🔋NN% появится в строке меню."
echo "  Автозапуск: Настройки → «Общие» → «Запускать при входе» (перенесён автоматически)."
echo "  Для разбивки CPU/GPU/DRAM открой поповер → «Установить хелпер…» (один клик, системный диалог пароля)."
