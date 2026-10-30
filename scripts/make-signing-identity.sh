#!/bin/bash
# Makes "Familiar Self-Signed", a code-signing certificate of our own in the login keychain, which build.sh then
# signs with. macOS remembers permissions (Accessibility, Microphone, Files & Folders) by who signed the app: with the
# ad-hoc signature every build counts as a new app and they're all asked again; with this one they're kept across
# builds and updates. It doesn't replace an Apple Developer ID: macOS still says it can't check the app the first time
# it's opened. Run once per Mac that builds, and keep a copy of the .p12 it leaves (password printed below): signing
# later releases with a different certificate resets everyone's permissions once.
set -euo pipefail
NAME="Familiar Self-Signed"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "$NAME is already in the keychain."; exit 0; fi
OUT="$HOME/Library/Application Support/Familiar Signing"
mkdir -p "$OUT" && chmod 700 "$OUT"
cd "$OUT"
cat > cert.conf <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 -config cert.conf -keyout key.pem -out cert.pem 2>/dev/null
PASSWORD="$(openssl rand -hex 12)"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" -out "$NAME.p12" -passout "pass:$PASSWORD" 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out "$NAME.p12" -passout "pass:$PASSWORD"
security import "$NAME.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign
rm -f key.pem cert.conf
echo "$PASSWORD" > p12-password.txt && chmod 600 p12-password.txt "$NAME.p12"
echo "Made $NAME. Backup: $OUT/$NAME.p12 (password in p12-password.txt)."
