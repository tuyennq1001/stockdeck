#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

SIMULATOR_NAME="${1:-iPhone 15 Pro}"

echo "Finding device ID for $SIMULATOR_NAME..."
DEVICE_ID=$(xcrun simctl list devices available | grep "$SIMULATOR_NAME" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')

if [ -z "$DEVICE_ID" ]; then
    echo "Simulator '$SIMULATOR_NAME' not found. Available devices:"
    xcrun simctl list devices available | grep -E "iPhone|iPad"
    exit 1
fi

echo "Booting simulator $SIMULATOR_NAME ($DEVICE_ID)..."
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
open -a Simulator

echo "Building iOS App for $SIMULATOR_NAME..."
xcodebuild -scheme StockDeck \
    -destination "id=$DEVICE_ID" \
    -configuration Debug \
    build 2>&1 | tail -20

echo "iOS build complete!"
