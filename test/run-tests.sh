#!/bin/bash
# Лёгкий тест-гейт Kelvin (без Xcode/XCTest — в духе raw-swiftc сборки).
# Покрывает: (1) юнит-тесты чистой логики на НАСТОЯЩЕМ коде; (2) покрытие локализации.
# Зовётся вручную и как жёсткий гейт в release.sh. Выход ≠0 → релиз останавливается.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
fail=0

echo "→ Юнит-тесты (чистая логика)"
TMP=$(mktemp -d)
# fmtRate компилируется с настоящим Sources/NetUsage.swift (тестируем код, не копию)
if xcrun swiftc -O Sources/NetUsage.swift test/units/main.swift -o "$TMP/fmtrate" 2>"$TMP/err"; then
    "$TMP/fmtrate" || fail=1
else
    echo "  ✗ не скомпилировался fmtRate-тест:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

echo "→ Юнит-тесты движка раскладок"
TMP=$(mktemp -d)
if xcrun swiftc -O Sources/KeyboardLayoutEngine.swift test/layout/main.swift -o "$TMP/layout" 2>"$TMP/err"; then
    "$TMP/layout" || fail=1
else
    echo "  ✗ не скомпилировался тест раскладок:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

echo "→ Покрытие локализации (uk/en/pt)"
bash test/check-i18n.sh || fail=1

if [ "$fail" -ne 0 ]; then echo "✗ Тесты упали"; exit 1; fi
echo "✓ Все тесты прошли"
