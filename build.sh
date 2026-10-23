#!/bin/zsh
# Builds BrightSync.app. No Xcode required, just the Swift toolchain.
set -e
cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="BrightSync.app"
VERSION="1.1"

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
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>BrightSync reads ambient light from Philips Hue sensors through your Hue bridge.</string>
    <key>NSBonjourServices</key><array><string>_hue._tcp</string></array>
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a stable identity for "Start at login".
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc signing failed, app still runs"

echo "Built $APP"
echo "Install with:  cp -R $APP /Applications/"
