#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP="$(pwd)/.build/StockDeck-Device.app"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
TRIPLE="arm64-apple-ios17.0"
BUNDLE_ID="com.terry.stockdeck.ios"
SIGN_ID="Apple Development: tuyennq1001@gmail.com (DGWT97FSZ4)"

echo "==> 1. Building StockDeck for physical iOS Device (arm64)..."
swift build --triple "$TRIPLE" --sdk "$SDK_PATH"

PRODUCTS=".build/arm64-apple-ios/debug"

echo "==> 2. Assembling iOS device app bundle..."
rm -rf "$APP"
mkdir -p "$APP"

cp "$PRODUCTS/StockDeck" "$APP/StockDeck"
chmod +x "$APP/StockDeck"

# Copy resource bundles
for bundle in "$PRODUCTS"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/"
done

# Compile asset catalog for iphoneos
echo "==> 3. Compiling asset catalog for device..."
xcrun --sdk iphoneos actool StockDeck/Assets.xcassets \
    --compile "$APP" \
    --output-partial-info-plist "$APP/assetcatalog_generated_info.plist" \
    --platform iphoneos \
    --target-device iphone \
    --target-device ipad \
    --minimum-deployment-target 17.0 \
    --app-icon AppIcon 2>/dev/null || true

# Copy icons & resources
cp StockDeck/Assets.xcassets/AppIcon.appiconset/*.png "$APP/" 2>/dev/null || true
cp "StockDeck/Resources/AppIcon.png" "$APP/" 2>/dev/null || true
cp "StockDeck/Resources/AppLogo.png" "$APP/" 2>/dev/null || true

# Write Info.plist
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
    <key>UILaunchScreen</key>
    <dict/>
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

# Find and embed Provisioning Profile
PROV_PROFILE="$(find ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/ ~/Library/MobileDevice/Provisioning\ Profiles/ -name "*.mobileprovision" 2>/dev/null | head -1 || true)"
ENTITLEMENTS_PLIST="/tmp/stockdeck_entitlements.plist"

if [[ -n "$PROV_PROFILE" && -f "$PROV_PROFILE" ]]; then
    echo "==> 4. Embedding provisioning profile from $PROV_PROFILE..."
    cp "$PROV_PROFILE" "$APP/embedded.mobileprovision"
    
    # Extract Entitlements
    security cms -D -i "$PROV_PROFILE" > /tmp/profile.plist
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" /tmp/profile.plist > "$ENTITLEMENTS_PLIST" 2>/dev/null || true
    rm -f /tmp/profile.plist
fi

echo "==> 5. Code signing with $SIGN_ID..."
if [[ -f "$ENTITLEMENTS_PLIST" ]]; then
    codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS_PLIST" --timestamp=none "$APP"
else
    codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
fi

echo "==> 6. Checking for connected physical iOS device..."
DEVICE_ID=""
for i in {1..10}; do
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null | grep -v "unavailable" | grep -E "iPhone|iPad" | head -1 | awk '{print $3}' || true)"
    if [[ -n "$DEVICE_ID" ]]; then
        break
    fi
    echo "[$i/10] Waiting for physical iPhone to be connected/unlocked..."
    sleep 2
done

if [[ -n "$DEVICE_ID" ]]; then
    echo "Found connected device: $DEVICE_ID"
    echo "Installing app onto device..."
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
    echo "Launching app on device..."
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || true
    echo "StockDeck iOS installed and launched on physical device successfully!"
else
    echo "--------------------------------------------------------------------------------"
    echo " ✅ App bundle built and signed 100% successfully at:"
    echo " $APP"
    echo ""
    echo " ⚠️ Physical device (Terry 14Pro) is currently offline/unavailable."
    echo " Để cài đặt ngay:"
    echo " 1. Cắm cáp USB iPhone vào máy Mac (hoặc mở khóa màn hình nếu dùng Wi-Fi)."
    echo " 2. Nhấn 'Tin cậy máy tính' (Trust this computer) trên màn hình iPhone."
    echo " 3. Chạy: ./dev-device.sh"
    echo "--------------------------------------------------------------------------------"
fi
