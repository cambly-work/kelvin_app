#!/usr/bin/env python3
"""
Подпись update-архива для Sparkle с использованием EdDSA.

Использование:
    python3 sign_update.py <path-to-update-archive> <private-key-base64>

Пример:
    python3 sign_update.py Kelvin-1.0.0.zip AnrH0DpRa4DrD50GQG4dcA0a37LKeHVH7kJA6GYpsKI=

Результат выводится в stdout в формате:
    sparkle:edSignature="<signature>" length="<size>" version="<version>"
"""

import nacl.signing
import base64
import hashlib
import sys
import os

def sign_update(archive_path, private_key_b64):
    if not os.path.exists(archive_path):
        print(f"✗ Файл не найден: {archive_path}", file=sys.stderr)
        sys.exit(1)
    
    # Декодируем приватный ключ
    try:
        private_key_bytes = base64.b64decode(private_key_b64)
        signing_key = nacl.signing.SigningKey(private_key_bytes)
    except Exception as e:
        print(f"✗ Ошибка декодирования приватного ключа: {e}", file=sys.stderr)
        sys.exit(1)
    
    # Читаем архив и вычисляем хеш
    with open(archive_path, 'rb') as f:
        archive_data = f.read()
    
    archive_size = len(archive_data)
    archive_hash = hashlib.sha256(archive_data).digest()
    
    # Подписываем хеш
    signature = signing_key.sign(archive_hash)
    signature_b64 = base64.b64encode(signature.signature).decode('utf-8')
    
    # Извлекаем версию из имени файла (если возможно)
    basename = os.path.basename(archive_path)
    version = "unknown"
    if "-" in basename and ".zip" in basename:
        # Предполагаем формат Kelvin-1.0.0.zip
        parts = basename.replace(".zip", "").split("-")
        if len(parts) >= 2:
            version = parts[-1]
    
    print(f"✓ Архив подписан успешно")
    print(f"  Файл: {basename}")
    print(f"  Размер: {archive_size} байт")
    print(f"  Версия: {version}")
    print(f"\nДобавьте в appcast.xml:")
    print(f'  sparkle:edSignature="{signature_b64}" length="{archive_size}" version="{version}"')
    
    return signature_b64, archive_size, version

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
