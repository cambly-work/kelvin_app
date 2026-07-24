#!/bin/bash
# Перезаписывает секцию блокировки доменов в /etc/hosts и сбрасывает DNS-кэш.
# Запускается как root через osascript (диалог пароля). Аргумент: путь к файлу со списком доменов.
LIST="$1"
M1="# >>> BatteryMeter blocklist >>>"
M2="# <<< BatteryMeter blocklist <<<"
TMP=$(mktemp)

# убрать прежнюю секцию BatteryMeter
sed "/$M1/,/$M2/d" /etc/hosts > "$TMP"

# добавить новую секцию (если список не пуст)
if [ -s "$LIST" ]; then
    {
        echo "$M1"
        while IFS= read -r d; do
            d="$(echo "$d" | tr -d '[:space:]')"
            [ -n "$d" ] && echo "0.0.0.0 $d"
        done < "$LIST"
        echo "$M2"
    } >> "$TMP"
fi

cp "$TMP" /etc/hosts
rm -f "$TMP"
dscacheutil -flushcache 2>/dev/null
killall -HUP mDNSResponder 2>/dev/null
echo "blocklist applied"
