#!/bin/zsh
# Builds OpenV380.app.
#   ./build-app.sh           dev:     sign with your local Apple Development cert and install to ~/Applications
#   ./build-app.sh release   release: ad-hoc sign (no personal identity) and zip for GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-dev}"
VERSION="1.0"

swift build -c release --product OpenV380

APP="build/OpenV380.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OpenV380 "$APP/Contents/MacOS/OpenV380"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OpenV380</string>
    <key>CFBundleDisplayName</key><string>OpenV380</string>
    <key>CFBundleIdentifier</key><string>com.openv380.mac</string>
    <key>CFBundleExecutable</key><string>OpenV380</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>OpenV380 connects to your V380 camera to show its live feed and recordings.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>av380.net</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

if [ "$MODE" = "release" ]; then
    # Ad-hoc signature: no Apple Developer identity is embedded, so nothing personal ships in the binary.
    codesign --force --deep --options runtime --sign - "$APP"
    ZIP="build/OpenV380-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Created $ZIP"
    echo "Upload it on the repo's Releases page. It is not notarized, so first launch is right-click → Open."
else
    # A stable Apple Development identity keeps the Keychain item trusted across local rebuilds.
    IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
    codesign --force --deep --options runtime --sign "${IDENTITY:--}" "$APP"
    mkdir -p ~/Applications
    rm -rf ~/Applications/OpenV380.app
    cp -R "$APP" ~/Applications/OpenV380.app
    echo "Installed ~/Applications/OpenV380.app"
fi
