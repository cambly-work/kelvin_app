#!/bin/bash
# Root-демон Kelvin: раз в ~секунду снимает powermetrics (нужен root)
# и атомарно кладёт последний сэмпл в файл, который читает приложение.
OUT="/Library/Application Support/Kelvin/power.txt"
TMP="$OUT.tmp"
ERR="/Library/Application Support/Kelvin/powermetrics.err"
mkdir -p "$(dirname "$OUT")"

while true; do
    # один сэмпл сэмплера cpu_power: строки вида "CPU Power: N mW", "GPU Power: …",
    # "DRAM Power: …", "Package Power: …" (на Intel) — их парсит PowerInfo.swift.
    /usr/bin/powermetrics --samplers cpu_power -i 900 -n 1 2> "$ERR" > "$TMP"
    chmod 644 "$ERR" 2>/dev/null || true
    if [ -s "$TMP" ]; then
        mv -f "$TMP" "$OUT"
        chmod 644 "$OUT"
    fi
    sleep 0.1
done
