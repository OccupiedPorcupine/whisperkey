#!/usr/bin/env bash
# Create a stable self-signed code-signing identity in the login keychain so
# WhisperKey gets the SAME signature on every rebuild. macOS ties Accessibility
# / Input Monitoring grants to that identity, so you grant permission once
# instead of after every build (the ad-hoc fingerprint changes each time).
#
# Idempotent: does nothing if the identity already exists.
set -euo pipefail

CERT_NAME="WhisperKey Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Use Apple's LibreSSL, not a Homebrew OpenSSL 3.x — the latter writes a
# PKCS#12 MAC that `security import` can't verify.
OPENSSL="/usr/bin/openssl"

# Note: NOT `-v` — a self-signed cert reads as "not trusted" and `-v` (valid
# only) would hide it, causing us to create a duplicate on every run.
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "==> code-signing identity \"$CERT_NAME\" already exists. Nothing to do."
    exit 0
fi

echo "==> generating self-signed code-signing certificate"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = WhisperKey Self-Signed
[ v3 ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

"$OPENSSL" pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:whisperkey \
    -name "$CERT_NAME" >/dev/null 2>&1

echo "==> importing into login keychain"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P whisperkey \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo ""
echo "Done. Identity \"$CERT_NAME\" installed."
echo "The first time you sign, macOS may ask to allow codesign to use the key —"
echo "click \"Always Allow\" so future builds don't prompt."
