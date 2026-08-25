#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP="$(pwd)/.build/StockDeck-iOS.app"
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TRIPLE="arm64-apple-ios17.0-simulator"
BUNDLE_ID="com.terry.stockdeck.ios"

echo "Building StockDeck for iOS Simulator..."
swift build --triple "$TRIPLE" --sdk "$SDK_PATH"

PRODUCTS=".build/arm64-apple-ios-simulator/debug"

echo "Assembling iOS app bundle..."
rm -rf "$APP"
mkdir -p "$APP"

cp "$PRODUCTS/StockDeck" "$APP/StockDeck"
chmod +x "$APP/StockDeck"

# Copy resources & bundles
for bundle in "$PRODUCTS"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/"
done

# Compile asset catalog (AppIcon and assets)
echo "Compiling asset catalog..."
xcrun --sdk iphonesimulator actool StockDeck/Assets.xcassets \
    --compile "$APP" \
    --output-partial-info-plist "$APP/assetcatalog_generated_info.plist" \
    --platform iphonesimulator \
    --target-device iphone \
    --target-device ipad \
    --minimum-deployment-target 17.0 \
    --app-icon AppIcon 2>/dev/null || true

# Copy icons & images if available
cp StockDeck/Assets.xcassets/AppIcon.appiconset/*.png "$APP/" 2>/dev/null || true
cp "StockDeck/Resources/AppIcon.png" "$APP/" 2>/dev/null || true
cp "StockDeck/Resources/AppLogo.png" "$APP/" 2>/dev/null || true

# Write iOS Info.plist
cat > "$APP/Info.plist" << 'PLISTEOF'
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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>AppIcon60x60</string>
            </array>
            <key>CFBundleIconName</key>
            <string>AppIcon</string>
        </dict>
    </dict>
    <key>CFBundleIcons~ipad</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>AppIcon60x60</string>
                <string>AppIcon76x76</string>
            </array>
            <key>CFBundleIconName</key>
            <string>AppIcon</string>
        </dict>
    </dict>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>StockDeck needs access to import and export your portfolio and watchlist files.</string>
    <key>UIFileSharingEnabled</key>
    <true/>
    <key>LSSupportsOpeningDocumentsInPlace</key>
    <true/>
</dict>
</plist>
PLISTEOF

echo "APPL????" > "$APP/PkgInfo"

# Code sign for simulator (ad-hoc)
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "Checking iOS Simulator..."
# Find booted device or pick default iPhone
BOOTED_DEVICE="$(xcrun simctl list devices | grep "(Booted)" | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()' || true)"

if [[ -z "$BOOTED_DEVICE" ]]; then
    DEVICE_ID="$(xcrun simctl list devices available | grep -E "iPhone 17 Pro \(" | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()' || true)"
    if [[ -z "$DEVICE_ID" ]]; then
        DEVICE_ID="$(xcrun simctl list devices available | grep -E "iPhone" | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()' || true)"
    fi
    echo "Booting simulator ($DEVICE_ID)..."
    xcrun simctl boot "$DEVICE_ID" || true
    TARGET_DEVICE="$DEVICE_ID"
else
    echo "Using already booted simulator ($BOOTED_DEVICE)..."
    TARGET_DEVICE="$BOOTED_DEVICE"
fi

open -a Simulator || true

echo "Terminating previous instance of $BUNDLE_ID..."
xcrun simctl terminate "$TARGET_DEVICE" "$BUNDLE_ID" 2>/dev/null || true

echo "Installing $APP on simulator..."
xcrun simctl install "$TARGET_DEVICE" "$APP"

echo "Launching $BUNDLE_ID..."
xcrun simctl launch "$TARGET_DEVICE" "$BUNDLE_ID"

echo "StockDeck iOS launched successfully!"
