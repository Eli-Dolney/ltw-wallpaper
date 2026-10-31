#!/bin/zsh
# Creates a local self-signed code-signing certificate ("Ltw Wallpaper Dev") in your login keychain and
# marks it trusted for code signing. build.sh signs with it when it exists.
#
# Why: an ad-hoc signature changes with every build, so macOS forgets privacy permissions (System Audio
# Recording for the volume mixer, folder access) and asks again after each ./run.sh. A stable identity
# keeps them. macOS will ask for your login password once, to trust the certificate.
set -e
NAME="Ltw Wallpaper Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."; exit 0
fi
TMP="$(mktemp -d)"
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:ltw >/dev/null 2>&1
KC="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/id.p12" -k "$KC" -P ltw -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Trust it for code signing (this is the step that asks for your password).
security add-trusted-cert -p codeSign -k "$KC" "$TMP/cert.pem"
rm -rf "$TMP"
echo "Created \"$NAME\". Rebuild with ./run.sh; the next permission prompts you accept will stick across builds."
