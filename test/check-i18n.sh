#!/bin/bash
# Проверка покрытия локализации: каждая запись Strings.table должна иметь uk/en/pt
# (частичная запись = баг → сломанная не-RU сборка). Плюс отчёт по ключам L(...),
# которых нет в таблице (они покажут русский во всех языках).
# Падает при частичных записях и при любом используемом ключе без перевода.
cd "$(dirname "$0")/.." || exit 2

python3 - <<'PY'
import re, glob, sys

LOC = "Sources/Localization.swift"
loc = open(LOC, encoding="utf-8").read()

# 1) записи таблицы: строки вида  "ключ": [.uk: "...", .en: "...", .pt: "..."],
entry_re = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*:\s*\[(.*)\]\s*,?\s*$', re.M)
table = {}
for m in entry_re.finditer(loc):
    key, body = m.group(1), m.group(2)
    if ".uk" not in body and ".en" not in body and ".pt" not in body:
        continue  # это не строка локализации (напр. другой словарь)
    table[key] = {lang: (f".{lang}:" in body or f".{lang} :" in body) for lang in ("uk", "en", "pt")}

partial = {k: v for k, v in table.items() if not all(v.values())}

# 2) все ключи-литералы L("...") по кодовой базе
key_re = re.compile(r'\bL\("((?:\\.|[^"\\])*)"\)')
used = set()
for f in glob.glob("Sources/*.swift"):
    for m in key_re.finditer(open(f, encoding="utf-8").read()):
        used.add(m.group(1))

missing = sorted(k for k in used if k not in table)

print(f"  таблица: {len(table)} записей · использований L(\"…\"): {len(used)}")
if missing:
    print(f"  ✗ {len(missing)} ключей L(\"…\") нет в таблице:")
    for k in missing[:20]:
        print(f"      · {k[:70]}")

if partial:
    print(f"  ✗ {len(partial)} ЧАСТИЧНЫХ записей (не хватает языка) — ЭТО БАГ:")
    for k, v in list(partial.items())[:20]:
        miss = ",".join(l for l, ok in v.items() if not ok)
        print(f"      · нет [{miss}]: {k[:60]}")
    sys.exit(1)

if missing:
    sys.exit(1)

print("  ✓ все записи таблицы полны (uk/en/pt)")
PY
