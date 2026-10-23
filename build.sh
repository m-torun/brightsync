#!/bin/zsh
# Builds BrightSync.app. No Xcode required, just the Swift toolchain.
set -e
cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="BrightSync.app"
VERSION="1.1"
# A build number per commit, so each build is distinguishable.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BrightSync"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BrightSync"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>BrightSync</string>
    <key>CFBundleIdentifier</key><string>app.brightsync.BrightSync</string>
    <key>CFBundleName</key><string>BrightSync</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>BrightSync reads ambient light from Philips Hue sensors through your Hue bridge.</string>
    <key>NSBonjourServices</key><array><string>_hue._tcp</string></array>
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Sign with a certificate of this Mac's own. macOS remembers some permissions
# (local network access) by the app's signature, and an ad-hoc signature
# changes with every build, so macOS would ask again after each one. The
# Keychain also tracks the exact build for apps without an Apple-issued
# certificate, so reading the Hue key still asks once per build. The certificate is made on the first build, in your login
# keychain, and never leaves this Mac. BRIGHTSYNC_ADHOC=1 signs ad hoc instead.
IDENTITY="BrightSync Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

identity_hash() {
    security find-identity "$KEYCHAIN" 2>/dev/null | grep "\"$IDENTITY\"" | head -1 | awk '{print $2}'
}

make_identity() {
    local dir
    dir=$(mktemp -d)
    cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    # The system's LibreSSL, present on every Mac. The key never leaves the
    # temporary folder except into the keychain.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
        -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null &&
    /usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
        -out "$dir/identity.p12" -passout pass:brightsync &&
    security import "$dir/identity.p12" -k "$KEYCHAIN" -P brightsync -T /usr/bin/codesign >/dev/null
    local result=$?
    rm -rf "$dir"
    return $result
}

SIGNED=""
if [[ -z "$BRIGHTSYNC_ADHOC" ]]; then
    HASH=$(identity_hash)
    if [[ -z "$HASH" ]]; then
        echo "Creating the code signing certificate \"$IDENTITY\" in your login keychain (once per Mac)."
        echo "macOS may ask once to let codesign use it: choose Always Allow."
        make_identity && HASH=$(identity_hash)
    fi
    if [[ -n "$HASH" ]] && codesign --force --sign "$HASH" "$APP" >/dev/null 2>&1; then
        SIGNED="with \"$IDENTITY\""
    else
        echo "note: could not sign with \"$IDENTITY\"; signing ad hoc, so macOS will ask for permissions again after each build"
    fi
fi
if [[ -z "$SIGNED" ]]; then
    codesign --force --sign - "$APP" >/dev/null 2>&1 && SIGNED="ad hoc" || echo "note: ad-hoc signing failed, app still runs"
fi

echo "Built $APP $VERSION ($BUILD), signed ${SIGNED:-not at all}"
echo "Install with:  cp -R $APP /Applications/"
