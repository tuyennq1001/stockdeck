#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

REQUESTED_NAME="${1:-}"

if [ -n "$REQUESTED_NAME" ]; then
    DEVICE_ID=$(xcrun simctl list devices available | grep "$REQUESTED_NAME" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/' || true)
else
    DEVICE_ID=$(xcrun simctl list devices available | grep "iPhone" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/' || true)
fi

if [ -z "$DEVICE_ID" ]; then
    echo "No matching iPhone simulator found. Available devices:"
    xcrun simctl list devices available | grep -E "iPhone|iPad"
    exit 1
fi

DEVICE_NAME=$(xcrun simctl list devices available | grep "$DEVICE_ID" | head -1 | sed -E 's/^[[:space:]]*([^(]+).*/\1/' | xargs)

echo "Booting simulator: $DEVICE_NAME ($DEVICE_ID)..."
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
open -a Simulator

SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
TRIPLE="arm64-apple-ios17.0-simulator"
APP_DIR=".build/StockDeck-iOS.app"

echo "Building StockDeck for iOS Simulator ($DEVICE_NAME)..."
swift build --sdk "$SDK_PATH" --triple "$TRIPLE"

# Find binary location dynamically
EXECUTABLE_PATH=$(find .build -path "*ios-simulator*/debug/StockDeck" -type f | head -1)

if [ -z "$EXECUTABLE_PATH" ]; then
    echo "Error: StockDeck executable for iOS Simulator not found!"
    exit 1
fi

PRODUCTS_DIR=$(dirname "$EXECUTABLE_PATH")

echo "Assembling iOS App Bundle ($APP_DIR)..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

cp "$EXECUTABLE_PATH" "$APP_DIR/StockDeck"
cp "StockDeck/Resources/AppIcon.png" "$APP_DIR/AppIcon.png" 2>/dev/null || true
cp "StockDeck/Resources/AppLogo.png" "$APP_DIR/AppLogo.png" 2>/dev/null || true

for bundle in "$PRODUCTS_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$APP_DIR/"
    fi
done

cat > "$APP_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>StockDeck</string>
    <key>CFBundleIdentifier</key>
    <string>com.simone.stockdeck.ios</string>
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
EOF

codesign --deep --sign - --force "$APP_DIR" 2>/dev/null || true

echo "Installing StockDeck on $DEVICE_NAME..."
xcrun simctl install "$DEVICE_ID" "$APP_DIR"

echo "Launching StockDeck on $DEVICE_NAME..."
xcrun simctl launch "$DEVICE_ID" com.simone.stockdeck.ios

echo "StockDeck iOS App launched successfully on $DEVICE_NAME!"
