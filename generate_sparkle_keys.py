#!/usr/bin/env python3
"""
Генерация EdDSA ключей для Sparkle Update Framework.

Использует PyNaCl для генерации пары ключей Ed25519.
Результат сохраняется в update_keys.txt (приватный + публичный).

ВАЖНО:
- НЕ коммитьте приватный ключ в репозиторий
- Сохраните приватный ключ в secure storage / CI secrets
- Публичный ключ вставьте в Info.plist как SUPublicEDKey
"""

import nacl.signing
import base64
import os
import sys

def generate_keys():
    print("━━ Генерация EdDSA ключей для Sparkle ━━")
    
    # Генерируем пару ключей Ed25519
    signing_key = nacl.signing.SigningKey.generate()
    verify_key = signing_key.verify_key
    
    # Кодируем в base64 (формат Sparkle)
    private_key_b64 = base64.b64encode(signing_key.encode()).decode('utf-8')
    public_key_b64 = base64.b64encode(verify_key.encode()).decode('utf-8')
    
    print(f"✓ Ключи сгенерированы успешно")
    print(f"\nПубличный ключ (для Info.plist):")
    print(f"  SUPublicEDKey: {public_key_b64}")
    print(f"\nПриватный ключ (для подписи обновлений):")
    print(f"  {private_key_b64}")
    
    # Сохраняем в файл
    output_file = "update_keys.txt"
    with open(output_file, 'w') as f:
        f.write("# Sparkle EdDSA Keys\n")
        f.write("# ВАЖНО: НЕ коммитьте этот файл в репозиторий!\n")
        f.write("# Приватный ключ должен храниться в secure storage\n\n")
        f.write(f"PUBLIC_KEY={public_key_b64}\n")
        f.write(f"PRIVATE_KEY={private_key_b64}\n")
    
    print(f"\n✓ Ключи сохранены в {output_file}")
    print(f"\nСледующие шаги:")
    print(f"  1. Скопируйте PUBLIC_KEY в Info.plist как SUPublicEDKey")
    print(f"  2. Сохраните PRIVATE_KEY в CI secrets (переменная SPARKLE_ED_PRIVATE_KEY)")
    print(f"  3. Добавьте {output_file} в .gitignore")
    print(f"  4. Удалите локальную копию приватного ключа после сохранения в CI")
    
    return public_key_b64, private_key_b64

if __name__ == "__main__":
    try:
        generate_keys()
    except Exception as e:
        print(f"✗ Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
