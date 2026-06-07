#!/bin/bash
# setup-cert.sh — создаёт локальный signing-сертификат (ОДИН РАЗ).
#
# Решает проблему сброса разрешений Accessibility и Input Monitoring
# при каждой пересборке. С именованным сертификатом macOS TCC хранит
# разрешение привязанным к сертификату, а не к хешу бинарника.
#
# Запусти: bash setup-cert.sh
# Потом: bash build.sh  (разрешения больше не слетают)

set -euo pipefail

CERT_NAME="Voice2Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "Voice2 — настройка постоянного signing-сертификата"
echo "===================================================="

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "✓ Сертификат '$CERT_NAME' уже есть — ничего делать не нужно."
    echo ""
    echo "Запускай: bash build.sh"
    exit 0
fi

echo "Создаю сертификат '$CERT_NAME' (RSA 2048, 10 лет)..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/cert.conf" << EOF
[req]
default_bits       = 2048
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $CERT_NAME
[ext]
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
basicConstraints     = critical,CA:false
subjectKeyIdentifier = hash
EOF

openssl req -newkey rsa:2048 -x509 -days 3650 -nodes \
    -config "$TMPDIR/cert.conf" \
    -keyout "$TMPDIR/cert.key" \
    -out    "$TMPDIR/cert.crt" 2>/dev/null

# PKCS12 с PBE-SHA1-3DES — единственный формат, который macOS security принимает
# от LibreSSL без ошибки "MAC verification failed"
openssl pkcs12 -export \
    -inkey "$TMPDIR/cert.key" \
    -in    "$TMPDIR/cert.crt" \
    -out   "$TMPDIR/cert.p12" \
    -name  "$CERT_NAME" \
    -passout pass:voice2dev \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 2>/dev/null

echo "Импортирую в login keychain..."
echo "(macOS может спросить пароль от keychain — введи пароль входа в систему)"

security import "$TMPDIR/cert.p12" \
    -P voice2dev \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign

# Trust для code signing (user domain, без sudo)
security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$TMPDIR/cert_exported.crt" 2>/dev/null
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$TMPDIR/cert_exported.crt" 2>/dev/null || true

echo ""
echo "Проверяю..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "✓ Готово! Сертификат '$CERT_NAME' активен."
    echo ""
    echo "Теперь запускай: bash build.sh"
    echo "Разрешения Accessibility и Input Monitoring сохранятся после каждой пересборки."
else
    echo "⚠️  Сертификат создан, но не виден как signing identity."
    echo "   Открой Keychain Access, найди '$CERT_NAME' → Get Info → Trust"
    echo "   → Code Signing = Always Trust"
    echo "   После этого build.sh заработает правильно."
fi
