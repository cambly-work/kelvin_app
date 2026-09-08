#!/bin/bash
# Лёгкий тест-гейт Kelvin (без Xcode/XCTest — в духе raw-swiftc сборки).
# Покрывает: (1) юнит-тесты чистой логики на НАСТОЯЩЕМ коде; (2) покрытие локализации.
# Зовётся вручную и как жёсткий гейт в release.sh. Выход ≠0 → релиз останавливается.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
fail=0

echo "→ Приватность crash reports"
TMP=$(mktemp -d)
cp test/units/crash_sanitizer_tests.swift "$TMP/main.swift"
if xcrun swiftc -O Sources/CrashReportSanitizer.swift "$TMP/main.swift" -o "$TMP/crash-sanitizer" 2>"$TMP/err"; then
    "$TMP/crash-sanitizer" || fail=1
else
    echo "  ✗ не скомпилировался CrashReportSanitizer-тест:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

echo "→ URLSession crash uploader (completion-handler compatibility)"
TMP=$(mktemp -d)
cp test/units/crash_uploader_session_tests.swift "$TMP/main.swift"
if xcrun swiftc -O -framework AppKit \
    Sources/AppConfig.swift Sources/Log.swift Sources/CrashBreadcrumb.swift \
    Sources/CrashReportSanitizer.swift Sources/CrashReportStore.swift \
    Sources/CrashReportUploader.swift "$TMP/main.swift" \
    -o "$TMP/crash-uploader-session" 2>"$TMP/err"; then
    "$TMP/crash-uploader-session" || fail=1
else
    echo "  ✗ не скомпилировался CrashReportUploader session-тест:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

echo "→ Юнит-тесты (чистая логика)"
TMP=$(mktemp -d)
# fmtRate компилируется с настоящим Sources/NetUsage.swift (тестируем код, не копию)
if xcrun swiftc -O Sources/NetUsage.swift test/units/main.swift -o "$TMP/fmtrate" 2>"$TMP/err"; then
    "$TMP/fmtrate" || fail=1
else
    echo "  ✗ не скомпилировался fmtRate-тест:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

echo "→ Форматирование метрик приложений"
TMP=$(mktemp -d)
cp test/units/app_energy_formatting_tests.swift "$TMP/main.swift"
if xcrun swiftc -O Sources/AppEnergyFormatting.swift "$TMP/main.swift" -o "$TMP/app-format" 2>"$TMP/err"; then
    "$TMP/app-format" || fail=1
else
    echo "  ✗ не скомпилировался AppEnergyFormatting-тест:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

echo "→ Сортировка и presentation-логика приложений"
TMP=$(mktemp -d)
cp test/units/app_energy_presentation_tests.swift "$TMP/main.swift"
if xcrun swiftc -O Sources/PowerInfo.swift Sources/AppEnergyFormatting.swift Sources/AppEnergyPresentation.swift "$TMP/main.swift" -o "$TMP/app-presentation" 2>"$TMP/err"; then
    "$TMP/app-presentation" || fail=1
else
    echo "  ✗ не скомпилировался AppEnergyPresentation-тест:"; sed 's/^/    /' "$TMP/err"; fail=1
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

echo "→ Совместимость SMC: ноутбуки, десктопы и неизвестные модели"
TMP=$(mktemp -d)
cp test/units/resolver_tests.swift "$TMP/main.swift"
if xcrun swiftc -O test/units/sensor_resolver_types.swift Sources/SensorResolver.swift "$TMP/main.swift" -o "$TMP/resolver" 2>"$TMP/err"; then
    "$TMP/resolver" || fail=1
else
    echo "  ✗ не скомпилировался SensorResolver-тест:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

echo "→ Покрытие локализации (uk/en/pt)"
bash test/check-i18n.sh || fail=1

echo "→ State machine автокоррекции"
TMP=$(mktemp -d)
if xcrun swiftc -O Sources/PendingCorrection.swift test/correction/main.swift -o "$TMP/correction" 2>"$TMP/err"; then
    "$TMP/correction" || fail=1
else
    echo "  ✗ не скомпилировался тест коррекции:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

echo "→ GPU model: pmset парсинг, capability detection, protocol types"
TMP=$(mktemp -d)
cp test/units/gpu_model_tests.swift "$TMP/main.swift"
if xcrun swiftc -O Sources/GPUInfo.swift Sources/ProcessRunner.swift Sources/PrivilegedProtocol.swift "$TMP/main.swift" -o "$TMP/gpu_model" 2>"$TMP/err"; then
    "$TMP/gpu_model" || fail=1
else
    echo "  ✗ не скомпилировался GPU model-тест:"; sed 's/^/    /' "$TMP/err"; fail=1
fi
rm -rf "$TMP"

if [ "$fail" -ne 0 ]; then echo "✗ Тесты упали"; exit 1; fi
echo "✓ Все тесты прошли"
