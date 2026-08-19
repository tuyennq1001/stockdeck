#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_DEST="/Applications/StockDeck.app"
PLIST="StockDeck/Info.plist"
PRODUCTS=".build/$(uname -m)-apple-macosx/release"

echo "1. Building release binary..."
swift build -c release 2>&1 | tail -3

echo "2. Assembling ${APP_DEST}..."
rm -rf "${APP_DEST}"
mkdir -p "${APP_DEST}/Contents/MacOS" "${APP_DEST}/Contents/Resources" "${APP_DEST}/Contents/Frameworks"

cp "${PRODUCTS}/StockDeck" "${APP_DEST}/Contents/MacOS/StockDeck"
cp "StockDeck/Resources/AppIcon.icns" "${APP_DEST}/Contents/Resources/AppIcon.icns"
cp "StockDeck/Resources/AppLogo.png" "${APP_DEST}/Contents/Resources/AppLogo.png" 2>/dev/null || true
cp "StockDeck/Resources/AppIcon.png" "${APP_DEST}/Contents/Resources/AppIcon.png" 2>/dev/null || true
cp "StockDeck/Resources/MenuBarIcon.png" "${APP_DEST}/Contents/Resources/MenuBarIcon.png" 2>/dev/null || true
cp -R "${PRODUCTS}/Sparkle.framework" "${APP_DEST}/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true

for bundle in "${PRODUCTS}"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "${APP_DEST}/Contents/Resources/"
done

install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_DEST}/Contents/MacOS/StockDeck" 2>/dev/null || true
cp "${PLIST}" "${APP_DEST}/Contents/Info.plist"

SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep -E "Apple Development|stockdeck_dev" | head -1 | awk -F'"' '{print $2}')
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "3. Signing with identity: ${SIGN_IDENTITY}..."
codesign --deep --sign "${SIGN_IDENTITY}" --force "${APP_DEST}" 2>/dev/null || codesign --deep --sign - --force "${APP_DEST}" 2>/dev/null

echo "4. Registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_DEST}"

echo "5. Restarting StockDeck..."
pkill -9 -f "Contents/MacOS/StockDeck" 2>/dev/null || true
sleep 0.5
open "${APP_DEST}"

echo "Successfully installed and launched /Applications/StockDeck.app!"
