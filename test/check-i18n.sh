#!/bin/bash
# Проверка покрытия локализации: каждая запись Strings.table должна иметь uk/en/pt
# (частичная запись = баг → сломанная не-RU сборка). Плюс отчёт по ключам L(...),
# которых нет в таблице (они покажут русский во всех языках).
# Падает при частичных записях и при любом используемом ключе без перевода.
cd "$(dirname "$0")/.." || exit 2

python3 - <<'PY'
import re, glob, json, sys

LOC = "Sources/Localization.swift"
loc = open(LOC, encoding="utf-8").read()

# 1) записи таблицы: строки вида  "ключ": [.uk: "...", .en: "...", .pt: "..."],
entry_re = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*:\s*\[(.*)\]\s*,?\s*$', re.M)
value_re = re.compile(r'\.(uk|en|pt)\s*:\s*"((?:\\.|[^"\\])*)"')

def unescape_swift(value):
    try:
        return json.loads('"' + value + '"')
    except (ValueError, json.JSONDecodeError):
        return value.replace(r'\n', '\n').replace(r'\"', '"').replace(r'\\', '\\')

table = {}
duplicates = []
for m in entry_re.finditer(loc):
    key, body = m.group(1), m.group(2)
    if ".uk" not in body and ".en" not in body and ".pt" not in body:
        continue  # это не строка локализации (напр. другой словарь)
    if key in table:
        duplicates.append(key)
    values = {lang: unescape_swift(value) for lang, value in value_re.findall(body)}
    table[key] = values

partial = {k: v for k, v in table.items() if any(lang not in v for lang in ("uk", "en", "pt"))}

# 2) все ключи-литералы L("...") по кодовой базе
key_re = re.compile(r'\bL\("((?:\\.|[^"\\])*)"\)')
used = set()
for f in glob.glob("Sources/*.swift"):
    for m in key_re.finditer(open(f, encoding="utf-8").read()):
        used.add(m.group(1))

missing = sorted(k for k in used if k not in table)

# 3) качество значений: наличие ключа недостаточно, если внутри осталась русская
# заглушка, пустая строка или Google Translate потерял printf-placeholder.
placeholder_re = re.compile(
    r'%(?:\d+\$)?[-+0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?'
    r'(?:hh|h|ll|l|L|z|j|t|q)?[%@diuoxXfFeEgGaAcspn]'
)
quality = []
for raw_key, values in table.items():
    key = unescape_swift(raw_key)
    expected_placeholders = sorted(placeholder_re.findall(key))
    for lang, value in values.items():
        if not value.strip():
            quality.append((raw_key, lang, "пустой перевод"))
        if lang in ("en", "pt") and re.search(r'[А-Яа-яЁёІіЇїЄє]', value):
            quality.append((raw_key, lang, "в переводе осталась кириллица"))
        if lang == "uk" and re.search(r'[ыэъёЫЭЪЁ]', value):
            quality.append((raw_key, lang, "в украинском переводе есть русские буквы"))
        actual_placeholders = sorted(placeholder_re.findall(value))
        if actual_placeholders != expected_placeholders:
            quality.append((raw_key, lang, f"placeholders {expected_placeholders} → {actual_placeholders}"))

print(f"  таблица: {len(table)} записей · использований L(\"…\"): {len(used)}")
if missing:
    print(f"  ✗ {len(missing)} ключей L(\"…\") нет в таблице:")
    for k in missing[:20]:
        print(f"      · {k[:70]}")

if partial:
    print(f"  ✗ {len(partial)} ЧАСТИЧНЫХ записей (не хватает языка) — ЭТО БАГ:")
    for k, v in list(partial.items())[:20]:
        miss = ",".join(l for l in ("uk", "en", "pt") if l not in v)
        print(f"      · нет [{miss}]: {k[:60]}")

if duplicates:
    print(f"  ✗ {len(duplicates)} дублирующихся ключей:")
    for k in duplicates[:20]:
        print(f"      · {k[:70]}")

if quality:
    print(f"  ✗ {len(quality)} проблем качества перевода:")
    for key, lang, issue in quality[:30]:
        print(f"      · [{lang}] {key[:55]} — {issue}")

if missing or partial or duplicates or quality:
    sys.exit(1)

print("  ✓ все записи таблицы полны и проверены (uk/en/pt, placeholders, script)")
PY
