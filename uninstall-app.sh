#!/bin/bash
# Удаляет приложение и автозапуск. Хелпер (root-демон) удаляется отдельно:
#   sudo /Applications/Kelvin.app/Contents/Resources/uninstall-helper.sh
# Миграция BatteryMeter → Kelvin: подчищаем старый бинарь/агент/бандл под прежним именем.
#
# Это точечный деинсталлятор из приложения. Для ПОЛНОЙ чистой переустановки со всеми
# службами (powerd/fand/privileged + legacy BatteryMeter) и проверками используйте
# clean-old-version.sh в корне репозитория — единый источник правды для списка целей.
AGENT="$HOME/Library/LaunchAgents/com.local.batterymeter.plist"
pkill -x Kelvin 2>/dev/null || true
pkill -x BatteryMeter 2>/dev/null || true
launchctl unload "$AGENT" 2>/dev/null || true
rm -f "$AGENT"
rm -rf "/Applications/Kelvin.app" "/Applications/BatteryMeter.app"
echo "✓ Приложение и автозапуск удалены."
echo "  Если ставил хелпер CPU/GPU/DRAM, удали и его:"
echo "  sudo rm -f /Library/LaunchDaemons/com.trykelvin.kelvin.powerd.plist && \\"
echo "  sudo rm -rf '/Library/Application Support/Kelvin'"
