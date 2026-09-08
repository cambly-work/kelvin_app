#!/usr/bin/env python3
"""Совместимая CLI-обёртка над официальным Sparkle bin/sign_update.

Использование:
    python3 sign_update.py <path-to-update-archive> <private-key-base64>

Пример:
    python3 sign_update.py Kelvin-1.0.0.zip AnrH0DpRa4DrD50GQG4dcA0a37LKeHVH7kJA6GYpsKI=

Результат выводится в stdout в формате:
    sparkle:edSignature="<signature>" length="<size>"
"""

import os
import re
import subprocess
import sys

def sign_update(archive_path, private_key_b64):
    if not os.path.exists(archive_path):
        print(f"✗ Файл не найден: {archive_path}", file=sys.stderr)
        sys.exit(1)
    
    if not private_key_b64.strip():
        print("✗ Приватный ключ пуст", file=sys.stderr)
        sys.exit(1)

    signer = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", "sign_update")
    if not os.path.isfile(signer) or not os.access(signer, os.X_OK):
        print(f"✗ Официальный Sparkle signer не найден: {signer}", file=sys.stderr)
        sys.exit(1)

    result = subprocess.run(
        [signer, "--ed-key-file", "-", archive_path],
        input=private_key_b64.strip(),
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        print(result.stderr.strip() or "✗ Sparkle sign_update завершился с ошибкой", file=sys.stderr)
        sys.exit(result.returncode)

    output = result.stdout.strip()
    print(output)
    signature_match = re.search(r'sparkle:edSignature="([^"]+)"', output)
    length_match = re.search(r'length="(\d+)"', output)
    if not signature_match or not length_match:
        print("✗ Неожиданный вывод Sparkle sign_update", file=sys.stderr)
        sys.exit(1)
    return signature_match.group(1), int(length_match.group(1))

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Использование: python3 sign_update.py <archive-path> <private-key-base64>", file=sys.stderr)
        print("\nПример:")
        print("  python3 sign_update.py Kelvin-1.0.0.zip AnrH0DpRa4DrD50GQG4dcA0a37LKeHVH7kJA6GYpsKI=")
        sys.exit(1)
    
    archive_path = sys.argv[1]
    private_key_b64 = sys.argv[2]
    
    try:
        sign_update(archive_path, private_key_b64)
    except Exception as e:
        print(f"✗ Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
