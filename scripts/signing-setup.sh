#!/bin/bash
# Creates a self-signed code-signing identity in a project-local keychain (.signing/), so rebuilt
# apps keep the same designated requirement and macOS privacy grants (Screen Recording etc.) persist.
# Nothing is added to the login keychain or the keychain search list.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.signing"; KC="$DIR/shotcraft.keychain-db"; PASS="shotcraft"
[ -f "$KC" ] && { echo "$KC exists"; exit 0; }
mkdir -p "$DIR"; cd "$DIR"
cat > cert.cnf <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Shotcraft Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem -config cert.cnf 2>/dev/null
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:$PASS 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:$PASS
security create-keychain -p $PASS "$KC"
security set-keychain-settings "$KC"   # no auto-lock
security unlock-keychain -p $PASS "$KC"
security import id.p12 -k "$KC" -P $PASS -T /usr/bin/codesign -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PASS "$KC" >/dev/null
rm -f key.pem id.p12
echo "Created $KC"
