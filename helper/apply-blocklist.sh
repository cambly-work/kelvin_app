#!/bin/bash
# Перезаписывает секцию блокировки доменов в /etc/hosts и сбрасывает DNS-кэш.
# Запускается как root через osascript (диалог пароля). Аргумент: путь к файлу со списком доменов.
set -euo pipefail

LIST="${1:-}"
HOSTS="/etc/hosts"
M1="# >>> Kelvin blocklist >>>"
M2="# <<< Kelvin blocklist <<<"
TMP="$(mktemp)"
trap 'rm -f "$TMP" "${HOSTS}.tmp.$$"' EXIT

# Никогда не трогаем hosts, если его нельзя прочитать — иначе рискуем обнулить системный файл.
[ -r "$HOSTS" ] || { echo "no readable /etc/hosts" >&2; exit 1; }

# убрать прежнюю секцию (строго от метки M1 до M2)
sed "/$M1/,/$M2/d" "$HOSTS" > "$TMP"

# добавить новую секцию (если список задан и не пуст)
if [ -n "$LIST" ] && [ -s "$LIST" ]; then
    {
        echo "$M1"
        while IFS= read -r d; do
            d="$(echo "$d" | tr -d '[:space:]')"
            # только синтаксически валидный хост (буквы/цифры/.-): отсекаем инъекцию вида "evil.com 1.2.3.4"
            case "$d" in
                ""|*[!A-Za-z0-9.-]*) continue ;;
            esac
            echo "0.0.0.0 $d"
        done < "$LIST"
        echo "$M2"
    } >> "$TMP"
fi

# Защита от потери данных: результат непустой и сохранил localhost — иначе НЕ пишем.
if [ ! -s "$TMP" ] || ! grep -Eq '127\.0\.0\.1[[:space:]]+localhost' "$TMP"; then
    echo "refusing to write: result is empty or missing localhost" >&2
    exit 1
fi

# бэкап + атомарная замена в пределах /etc (mv атомарен на одной ФС), права 644 root:wheel
cp -p "$HOSTS" "${HOSTS}.kelvin.bak" 2>/dev/null || true
chmod 600 "${HOSTS}.kelvin.bak" 2>/dev/null || true   # бэкап только для root — не плодим world-readable копию блок-листа
cat "$TMP" > "${HOSTS}.tmp.$$"
chmod 644 "${HOSTS}.tmp.$$"
mv -f "${HOSTS}.tmp.$$" "$HOSTS"

dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true
echo "blocklist applied"
