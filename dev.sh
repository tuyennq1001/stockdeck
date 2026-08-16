#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP=".build/StockDeck-Dev.app"
PLIST="StockDeck/Info.plist"

# Reuse the real marketing/build version so the dev header reads e.g. "StockDeck v1.5.2 DEV".
DEV_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
DEV_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

echo "Building..."
swift build -c release 2>&1 | tail -3

PRODUCTS=".build/$(uname -m)-apple-macosx/release"

echo "Assembling DEV app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$PRODUCTS/StockDeck" "$APP/Contents/MacOS/StockDeck"
cp "StockDeck/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "StockDeck/Resources/AppLogo.png" "$APP/Contents/Resources/AppLogo.png" 2>/dev/null || true
cp "StockDeck/Resources/AppIcon.png" "$APP/Contents/Resources/AppIcon.png" 2>/dev/null || true
cp "StockDeck/Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png" 2>/dev/null || true
cp -R "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

for bundle in "$PRODUCTS"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/StockDeck" 2>/dev/null || true

# Dev Info.plist: different bundle ID, no SUFeedURL
cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>StockDeck</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <!-- Launch via `open` (Finder-style) so macOS 26 registers the Menu Bar item
         reliably and keeps the process alive. Keep this bundle ID stable: the
         Binance API credentials live in the keychain under this identity, and a
         fresh suffix silently breaks access to them (the app re-asks for keys).
         If the Menu Bar item gets stuck hidden, re-enable it in System Settings
         rather than bumping the suffix. -->
    <string>com.terry.stockdeck.development.v4</string>
    <key>CFBundleName</key>
    <string>StockDeck Dev</string>
    <key>CFBundleShortVersionString</key>
    <string>${DEV_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${DEV_BUILD}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep -E "Apple Development|stockdeck_dev" | head -1 | awk -F'"' '{print $2}')
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "Signing DEV app with identity: ${SIGN_IDENTITY}..."
codesign --deep --sign "${SIGN_IDENTITY}" --force "$APP" 2>/dev/null || codesign --deep --sign - --force "$APP" 2>/dev/null

echo "Killing old StockDeck process instances..."
pkill -9 -f "StockDeck-Dev\.app/Contents/MacOS/StockDeck" 2>/dev/null || true
pkill -9 -f "StockDeck\.app/Contents/MacOS/StockDeck" 2>/dev/null || true
sleep 0.5

echo "Launching StockDeck DEV..."
# Launch via `open` (Finder-style): macOS 26 registers the Menu Bar item
# correctly and keeps the process alive, which a raw binary launch does not.
# By default the desktop window auto-opens so the app is visibly running.
# The Menu Bar icon itself is governed by macOS 26's per-app Control Center
# toggle (System Settings → Control Center → Menu Bar items): if it is missing
# or hidden, enable it there; bumping Bundle ID / autosave name does not help.
SD_OPEN_WINDOW="${SD_OPEN_WINDOW:-1}"
if [ "$SD_OPEN_WINDOW" = "1" ]; then
    open "$APP" --env SD_OPEN_WINDOW=1
else
    open "$APP" --env SD_OPEN_WINDOW=0
fi
