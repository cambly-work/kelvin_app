#!/bin/bash
# Генерация EdDSA ключей для Sparkle updater
# Приватный ключ хранится в keychain, публичный встраивается в Info.plist

set -e
cd "$(dirname "$0")"

echo "━━ Генерация EdDSA ключей для Sparkle ━━"

# Проверка наличия инструментов Sparkle
if [ ! -f "bin/generate_keys" ]; then
    echo "✗ bin/generate_keys не найден. Скачайте Sparkle.framework и извлеките инструменты."
    exit 1
fi

# Генерация ключей (выводит приватный и публичный ключ)
echo "→ Генерация пары ключей..."
./bin/generate_keys | tee update_keys.txt

echo ""
echo "✓ Ключи сгенерированы:"
echo "  - update_keys.txt содержит оба ключа"
echo "  - Приватный ключ: сохраните в secure storage / CI secrets"
echo "  - Публичный ключ: вставьте в Info.plist как SUPublicEDKey"
echo ""
echo "Для подписи обновлений используйте:"
echo "  ./bin/sign_update --ed-key-file <private-key-file> <path-to-update-archive>"
echo ""
echo "ВАЖНО:"
echo "  - НЕ коммитьте приватный ключ в репозиторий"
echo "  - Добавьте update_keys.txt в .gitignore"
echo "  - Для CI: экспортируйте приватный ключ в переменную окружения или keychain"
