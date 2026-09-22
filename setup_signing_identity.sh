#!/bin/bash
# One-time setup: creates a stable, local self-signed code-signing certificate
# so macOS's permission grants (Camera/Calendar/Automation) survive rebuilds.
#
# Why this is needed: ad-hoc signing (`codesign --sign -`) pins TCC's trust
# decision to the exact binary hash, so ANY rebuild — even a one-line change —
# invalidates every permission grant and forces a re-prompt. Signing with a
# real certificate instead pins trust to the CERTIFICATE's identity, which
# stays constant across rebuilds, so grants persist. This is the same
# mechanism a paid Developer ID uses — just self-issued and free.
#
# Safe to re-run: skips if the identity already exists.
set -euo pipefail

NAME="MyNotch Local Signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "✓ '$NAME' already exists in the login keychain — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Generating a 20-year self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 7300 -nodes \
    -subj "/CN=${NAME}" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

echo "▸ Packaging for import (-legacy: macOS's importer needs the older PKCS12 cipher)…"
openssl pkcs12 -export -out "$TMP/bundle.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:temporary -legacy >/dev/null 2>&1

echo "▸ Importing into the login keychain…"
security import "$TMP/bundle.p12" -k ~/Library/Keychains/login.keychain-db \
    -P temporary -T /usr/bin/codesign -A

echo "✓ Created '$NAME'. build.sh will use it automatically from now on."
echo "  (You'll need to re-grant Camera/Calendar/Automation ONE more time after"
echo "  the next build — after that, permissions should survive rebuilds.)"
