#!/bin/bash
# Ставит root-демон управления вентиляторами (fand). Запускать через sudo.
# Демон форсирует обороты по профилю из ~/Library/Application Support/Kelvin/fan-profile.json.
# Защита: перегрев → максимум; остановка/удаление демона → системный авто-режим.
set -euo pipefail
if [ "$(id -u)" != "0" ]; then echo "Запусти через sudo:  sudo \"$0\""; exit 1; fi

RUSER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
# Валидируем имя пользователя: допускаем только символы, безопасные для путей/передачи в chown.
# Раньше здесь был `eval echo "~$RUSER"` — eval от переменной окружения в root-контексте
# позволяет инъекцию команд/путей. Заменено на безопасный lookup через dscl.
if ! printf '%s' "$RUSER" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    echo "Некорректное имя пользователя: $RUSER" >&2
    exit 1
fi
# dscl выводит "NFSHomeDirectory: /Users/foo" — берём всё после ": " чтобы
# корректно обработать home с пробелами (напр. /Users/John Doe).
RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')
[ -n "$RHOME" ] || RHOME="${HOME:-/tmp}"
SUPPORT="/Library/Application Support/Kelvin"
UDIR="$RHOME/Library/Application Support/Kelvin"
PROFILE="$UDIR/fan-profile.json"
PLIST="/Library/LaunchDaemons/com.trykelvin.kelvin.fand.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"

# Миграция BatteryMeter → Kelvin: убираем СТАРЫЙ демон вентиляторов под прежним
# именем, чтобы переустановка хелпера не оставила осиротевший root-демон.
OLD_PLIST="/Library/LaunchDaemons/com.local.batterymeter.fand.plist"
launchctl bootout system/com.local.batterymeter.fand 2>/dev/null || true
launchctl unload "$OLD_PLIST" 2>/dev/null || true
rm -f "$OLD_PLIST" "/Library/Application Support/BatteryMeter/batterymeter-fand"

echo "→ Копирую демон"
# Защита от symlink-атаки: отказываемся, если SUPPORT — символическая ссылка
# (атакующий мог предварительно разместить symlink, чтобы перенаправить root-запись).
if [ -L "$SUPPORT" ]; then
    echo "✗ $SUPPORT — символическая ссылка. Установка отменена (потенциальная атака)." >&2
    exit 1
fi
mkdir -p "$SUPPORT"
# mktemp -d внутри root-owned каталога: непредсказуемые временные пути вместо PID.
TMPDIR_KELVIN=$(mktemp -d "$SUPPORT/.kelvin-install.XXXXXX") || { echo "✗ mktemp не удалось" >&2; exit 1; }
trap 'rm -rf "$TMPDIR_KELVIN"' EXIT

# Атомарная установка бинарника: временный файл → права/владелец → mv.
TMP_BIN="$TMPDIR_KELVIN/kelvin-fand"
cp "$SRC/kelvin-fand" "$TMP_BIN"
chown root:wheel "$TMP_BIN"
chmod 755 "$TMP_BIN"
mv -f "$TMP_BIN" "$SUPPORT/kelvin-fand"

TMP_VER="$TMPDIR_KELVIN/kelvin-fand.version"
printf '%s\n' "2" > "$TMP_VER"
chown root:wheel "$TMP_VER"
chmod 644 "$TMP_VER"
mv -f "$TMP_VER" "$SUPPORT/kelvin-fand.version"

echo "→ Профиль: $PROFILE"
mkdir -p "$UDIR"
[ -f "$PROFILE" ] || echo '{"name":"Авто","mode":"auto"}' > "$PROFILE"
chown -R "$RUSER" "$UDIR" 2>/dev/null || true

echo "→ Устанавливаю LaunchDaemon"
TMP_PLIST="$TMPDIR_KELVIN/com.trykelvin.kelvin.fand.plist"
cat > "$TMP_PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.trykelvin.kelvin.fand</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SUPPORT/kelvin-fand</string>
        <string>--follow-console-user</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardErrorPath</key><string>/var/log/kelvin-fand.err</string>
</dict>
</plist>
PL
# Проверка plist ДО установки (atomic: валидный временный файл → права → mv).
if ! plutil -lint "$TMP_PLIST" >/dev/null 2>&1; then
    echo "✗ Сгенерированный plist невалиден — установка отменена." >&2
    rm -f "$TMP_PLIST"
    exit 1
fi
chown root:wheel "$TMP_PLIST"; chmod 644 "$TMP_PLIST"
mv -f "$TMP_PLIST" "$PLIST"
launchctl bootout system/com.trykelvin.kelvin.fand 2>/dev/null || true
if ! launchctl bootstrap system "$PLIST"; then
    echo "✗ launchd не принял системный компонент." >&2
    exit 1
fi
launchctl enable system/com.trykelvin.kelvin.fand
launchctl kickstart -k system/com.trykelvin.kelvin.fand

# Poll состояния с таймаутом: launchd после kickstart может быть в переходном
# состоянии (starting/waiting/throttle). Один мгновенный снимок «не running»
# НЕ доказывает сбой — ждём до POLL_TIMEOUT.
POLL_TIMEOUT=20
POLL_INTERVAL=0.3
elapsed=0
running=0
while [ "$(echo "$elapsed < $POLL_TIMEOUT" | bc -l)" = "1" ]; do
    if launchctl print system/com.trykelvin.kelvin.fand 2>/dev/null | grep -q "state = running"; then
        running=1
        break
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$(echo "$elapsed + $POLL_INTERVAL" | bc -l)
done

if [ "$running" != "1" ]; then
    echo "✗ Не удалось запустить компонент управления вентиляторами и зарядом." >&2
    echo "" >&2
    echo "Диагностика:" >&2
    echo "--- launchctl print system/com.trykelvin.kelvin.fand ---" >&2
    launchctl print system/com.trykelvin.kelvin.fand 2>&1 | grep -E "state = |last exit code = |pid = " >&2 || true
    echo "--- stderr-лог (/var/log/kelvin-fand.err, последние строки) ---" >&2
    tail -n 20 /var/log/kelvin-fand.err 2>/dev/null || echo "(лог отсутствует)" >&2
    echo "--- plist и payload ---" >&2
    ls -l "$PLIST" "$SUPPORT/kelvin-fand" 2>&1 | sed 's/^/  /' >&2
    plutil -lint "$PLIST" 2>&1 | sed 's/^/  /' >&2
    # НЕ делаем bootout: состояние могло быть переходным, а journal/exit-code
    # помогает диагностике. Перезапуск скрипта повторит попытку.
    exit 1
fi

echo "✓ Демон вентиляторов запущен."
echo "  Управление активирует выбранный в настройках профиль (кроме «Авто»)."
echo "  Защита: перегрев → максимум; «Авто» или удаление демона → системный режим."
