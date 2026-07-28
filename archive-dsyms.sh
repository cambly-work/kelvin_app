#!/bin/bash
# Скрипт для архивации dSYM файлов после сборки Kelvin.app
# Используется для symbolication crash reports

set -e
cd "$(dirname "$0")"

APP="Kelvin.app"
BIN="Kelvin"
DWARF_DSYM_FOLDER_PATH="${DWARF_DSYM_FOLDER_PATH:-.}"

echo "→ Архивация dSYM для symbolication…"

# Проверяем, существует ли приложение
if [ ! -d "$APP" ]; then
    echo "✗ Приложение $APP не найдено. Сначала выполните build.sh"
    exit 1
fi

# Создаём директорию для dSYM
DSYM_OUTPUT_DIR="dsyms"
mkdir -p "$DSYM_OUTPUT_DIR"

# Получаем UUID бинаря для каждой архитектуры
echo "  Извлечение UUID бинаря…"

# Для Universal Binary нужно получить UUID для каждой архитектуры
TMPDIR_UUID=$(mktemp -d)

# Извлекаем UUID для arm64
UUID_ARM64=$(lipo -info "$APP/Contents/MacOS/$BIN" 2>/dev/null | grep -o 'arm64' && \
             dwarfdump --uuid "$APP/Contents/MacOS/$BIN" 2>/dev/null | grep arm64 | awk '{print $2}' || echo "")

# Извлекаем UUID для x86_64
UUID_X86_64=$(lipo -info "$APP/Contents/MacOS/$BIN" 2>/dev/null | grep -o 'x86_64' && \
              dwarfdump --uuid "$APP/Contents/MacOS/$BIN" 2>/dev/null | grep x86_64 | awk '{print $2}' || echo "")

rm -rf "$TMPDIR_UUID"

# Если есть dSYM от сборки, копируем его
if [ -d "$APP.dSYM" ]; then
    echo "  Копирование $APP.dSYM…"
    cp -R "$APP.dSYM" "$DSYM_OUTPUT_DIR/"
    
    # Создаём manifest файл
    MANIFEST_FILE="$DSYM_OUTPUT_DIR/manifest.json"
    
    # Получаем версию из Info.plist
    APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
    APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
    
    # UUID из dSYM
    DSYM_UUID=$(dwarfdump --uuid "$APP.dSYM" 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
    
    cat > "$MANIFEST_FILE" << EOF
{
    "app_name": "Kelvin",
    "bundle_id": "com.trykelvin.kelvin",
    "version": "$APP_VERSION",
    "build": "$APP_BUILD",
    "binary_uuids": {
        "arm64": "$UUID_ARM64",
        "x86_64": "$UUID_X86_64"
    },
    "dsym_uuid": "$DSYM_UUID",
    "dsym_file": "$APP.dSYM",
    "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "schema_version": 1
}
EOF
    
    echo "  Manifest создан: $MANIFEST_FILE"
    
    # Архивируем dSYM с manifest
    ARCHIVE_NAME="Kelvin-${APP_VERSION}-${APP_BUILD}-dsyms.tar.gz"
    tar -czf "$DSYM_OUTPUT_DIR/$ARCHIVE_NAME" -C "$DSYM_OUTPUT_DIR" "$APP.dSYM" manifest.json
    
    echo "  ✓ Архив создан: $DSYM_OUTPUT_DIR/$ARCHIVE_NAME"
    
    # Выводим информацию для разработчика
    echo ""
    echo "→ Информация для symbolication:"
    echo "  Version: $APP_VERSION ($APP_BUILD)"
    echo "  Binary UUID (arm64): $UUID_ARM64"
    echo "  Binary UUID (x86_64): $UUID_X86_64"
    echo "  dSYM UUID: $DSYM_UUID"
    echo ""
    echo "→ Загрузите этот архив в систему symbolication:"
    echo "  $DSYM_OUTPUT_DIR/$ARCHIVE_NAME"
    
else
    echo "  (dSYM не найден — возможно, сборка без отладочной информации)"
    echo "  Для включения dSYM добавьте в swiftc флаги: -g -emit-dwarf-types=full"
fi

echo "✓ Готово"
