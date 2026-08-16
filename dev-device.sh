#!/usr/bin/env bash
set -euo pipefail

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
TRIPLE="arm64-apple-ios17.0"
APP_DIR=".build/StockDeck-iOS-Device.app"

echo "1. Building StockDeck for physical iOS device..."
swift build --sdk "$SDK_PATH" --triple "$TRIPLE"

EXECUTABLE_PATH=$(find .build -name "StockDeck" -path "*ios*/debug/*" | head -1)

if [ -z "$EXECUTABLE_PATH" ]; then
    echo "Error: StockDeck executable for iOS not found!"
    exit 1
fi

echo "2. Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

cp "$EXECUTABLE_PATH" "$APP_DIR/StockDeck"
cp "StockDeck/Resources/AppIcon.png" "$APP_DIR/AppIcon.png" 2>/dev/null || true
cp "StockDeck/Resources/AppLogo.png" "$APP_DIR/AppLogo.png" 2>/dev/null || true

cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>StockDeck</string>
    <key>CFBundleIdentifier</key>
    <string>com.terry.stockdeck.ios</string>
    <key>CFBundleName</key>
    <string>StockDeck</string>
    <key>CFBundleDisplayName</key>
    <string>StockDeck</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>MinimumOSVersion</key>
    <string>17.0</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "3. Signing app bundle..."
CERT_NAME="Apple Development: tuyennq1001@gmail.com (DGWT97FSZ4)"
codesign --force --deep --sign "$CERT_NAME" "$APP_DIR" 2>/dev/null || codesign --force --deep --sign - "$APP_DIR"

echo "4. Installing StockDeck on Terry 14Pro..."
xcrun devicectl device install app --device FE22B92E-44F0-5EED-8604-9C5233ACDA8A "$APP_DIR"

echo "5. Launching StockDeck on Terry 14Pro..."
xcrun devicectl device process launch --device FE22B92E-44F0-5EED-8604-9C5233ACDA8A com.terry.stockdeck.ios

echo "StockDeck iOS App launched successfully on iPhone 14 Pro!"
