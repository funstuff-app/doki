#!/bin/bash
# Create a STABLE self-signed code-signing identity in a dedicated keychain, so
# Doki's signature (and its Accessibility/TCC grant) stays constant across rebuilds.
# Run once. Idempotent.
set -euo pipefail
IDENT="Doki Self-Signed"
KC="$(cd "$(dirname "$0")" && pwd)/doki-sign.keychain-db"
KCPASS="Doki"

if [ -f "$KC" ] && security find-certificate -c "$IDENT" "$KC" >/dev/null 2>&1; then
  echo "identity '$IDENT' already present"; exit 0
fi

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$KCPASS" "$KC"

D=$(mktemp -d)
# System LibreSSL writes a macOS-readable PKCS12 MAC (brew OpenSSL 3 would need -legacy).
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -nodes \
  -subj "/CN=$IDENT" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
/usr/bin/openssl pkcs12 -export -macalg sha1 -inkey "$D/key.pem" -in "$D/cert.pem" \
  -out "$D/id.p12" -passout pass:pass -name "$IDENT"
security import "$D/id.p12" -k "$KC" -P "pass" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1 || true
rm -rf "$D"

# Add our keychain to the search list (preserve others; drop any stale dup of ours).
EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//' | grep -v "doki-sign.keychain-db" || true)
security list-keychains -d user -s "$KC" $EXISTING

# Verify by the cert (self-signed certs don't appear in `find-identity -v`).
if security find-certificate -c "$IDENT" "$KC" >/dev/null 2>&1; then
  echo "created '$IDENT' in $KC"
else
  echo "ERROR: '$IDENT' not in keychain"; exit 1
fi
