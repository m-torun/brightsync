#!/bin/zsh
# Creates a self-signed code signing certificate called "BrightSync Dev" in
# your login keychain, and signs builds with it from then on.
#
# Why bother: Accessibility permission (needed for the brightness keys) is tied
# to an app's code signature. An ad-hoc signature changes on every build, so
# macOS treats each build as a new app and the permission has to be granted
# again. A certificate keeps the identity stable, so you grant it once.
set -e
NAME="BrightSync Dev"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the login keychain."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# Apple's keychain cannot read OpenSSL 3's default PKCS#12 encryption.
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:brightsync -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
    -P brightsync -T /usr/bin/codesign -A

echo "Created \"$NAME\". ./build.sh will use it automatically."
