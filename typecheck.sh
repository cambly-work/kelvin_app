#!/bin/bash
# Быстрая проверка всех Swift-исходников без линковки, упаковки, universal binary
# и подписи. Используется во время разработки перед дорогим ./build.sh.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${KELVIN_DEV_ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "✗ Неподдерживаемая архитектура KELVIN_DEV_ARCH=$ARCH"
        exit 2
        ;;
esac

echo "→ Typecheck Kelvin ($ARCH)…"
find Sources -maxdepth 1 -name '*.swift' -print0 \
    | xargs -0 xcrun swiftc \
        -Onone \
        -target "$ARCH-apple-macos11" \
        -F "$PWD" \
        -framework Sparkle \
        -typecheck
echo "✓ Swift typecheck прошёл"
